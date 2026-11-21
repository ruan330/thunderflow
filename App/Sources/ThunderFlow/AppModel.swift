import AVFoundation
import AppKit
import Foundation
import Observation
import ThunderAudio
import ThunderCore
import ThunderEngines
import ThunderSession
import ThunderUI

/// 整個 App 的狀態：目前在哪一頁、正在錄的那一場、過去錄音的清單。
///
/// 這裡只做組裝與畫面需要的狀態；規則都在 ThunderKit（錄音、引擎、結束處理各自有測試）。
@MainActor
@Observable
final class AppModel {
    enum Page: Hashable { case live, library, settings }
    enum LiveState { case idle, starting, recording, paused, stopping }

    /// 來源的選項。
    enum SourceChoice: Hashable {
        case system
        case microphone(uid: String)  // 空字串：系統預設的麥克風
        case file(URL)
    }

    var page: Page = .live
    let settings = AppSettings()
    let captions = LiveCaptionModel()

    // MARK: 即時翻譯頁

    var liveState: LiveState = .idle
    var elapsed: TimeInterval = 0
    var level: Float = 0
    /// 頁面頂端的橫幅：發生了什麼、錄音有沒有受影響、該怎麼處理。
    var banner: String?
    var title = ""
    var event = ""
    var speaker = ""
    /// 這一場的關鍵詞，一行一個。
    var sessionKeywords = ""
    var source: SourceChoice
    var devices: [AudioInputDevice] = []
    var sourceDescription = ""

    // MARK: 過去錄音

    var sessions: [SessionLibrary.Item] = []
    /// 正在做結束處理的場次，以及目前做到哪一步。
    var processing: [UUID: String] = [:]
    var selectedSession: UUID?
    var searchText = ""

    private var recording: LiveRecording?
    private var ticker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var lastCallbackCount = 0
    private var silentTicks = 0
    /// 連續幾次量到的音量都接近零；以及這一場到目前為止有沒有聽到過聲音。
    private var quietTicks = 0
    private var heardSound = false

    init() {
        let key = UserDefaults.standard.string(forKey: "sourceKey") ?? "system"
        source = key == "system" ? .system : .microphone(uid: key)
    }

    var isRecording: Bool { liveState == .recording || liveState == .paused }

    // MARK: 啟動之後

    /// 第一個畫面出現之後才做的事：讀清單、把上次沒做完的場次接著做完。不擋畫面。
    func didAppear() {
        refreshDevices()
        reloadLibrary()
        resumeUnfinished()
        SelfTest.runIfRequested(self)
    }

    func refreshDevices() {
        devices = AudioDevices.inputDevices()
    }

    // MARK: 開始與停止

    func start() async {
        guard liveState == .idle else { return }
        banner = nil
        guard let key = Credentials.load(), !key.isEmpty else {
            settings.hasKey = false
            banner = "還沒有設定 OpenAI API Key。請到「設定」貼上你的 Key，再回來按開始。"
            page = .settings
            return
        }
        settings.hasKey = true
        if case .microphone = source, !(await Permissions.microphone()) {
            banner = "沒有麥克風的權限，所以沒有開始錄音。請到「系統設定 → 隱私權與安全性 → 麥克風」打開 ThunderFlow。"
            return
        }
        if let free = Self.freeSpace(at: settings.workingRoot), free < 2_000_000_000 {
            banner = "磁碟剩餘空間不到 2 GB。錄音每小時約需要 350 MB 的暫存空間。"
        }

        liveState = .starting
        captions.reset()
        elapsed = 0
        let keywords = AppSettings.lines(settings.keywords) + AppSettings.lines(sessionKeywords)

        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.endpoint = settings.realtimeEndpoint
        configuration.link.settings.model = settings.transcriptionModel
        configuration.link.settings.delay = settings.delay
        configuration.link.settings.keywords = keywords
        configuration.link.settings.prompt = Self.prompt(title: title, event: event, speaker: speaker)
        configuration.translation.model = settings.liveTextModel
        configuration.translation.provisional = settings.showsProvisional
        configuration.translation.title = title
        configuration.translation.event = event
        configuration.translation.speaker = speaker
        configuration.translation.keywords = keywords
        let engine = TranscribeTranslateEngine(
            configuration: configuration, apiKey: key, textModel: OpenAITextModel(apiKey: key, baseURL: settings.textBaseURL))

        var options = LiveRecording.Options(source: captureSource, workingRoot: settings.workingRoot)
        options.title = title.trimmingCharacters(in: .whitespaces)
        options.event = event.trimmingCharacters(in: .whitespaces)
        options.speaker = speaker.trimmingCharacters(in: .whitespaces)
        options.keywords = keywords
        options.engineName = "\(settings.transcriptionModel)＋\(settings.liveTextModel)"
        let captions = captions
        let recording = LiveRecording(options: options, engine: engine) { captions.receive($0) }
        recording.onSourceEnded = { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        do {
            try recording.start()
        } catch {
            banner = "無法開始錄音：\(error)"
            liveState = .idle
            return
        }
        self.recording = recording
        sourceDescription = recording.sourceDescription
        liveState = .recording
        // 錄音中不讓電腦因為閒置而睡眠
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "錄音中")
        startTicker()
    }

    func stop() async {
        guard let recording, isRecording else { return }
        liveState = .stopping
        ticker?.cancel()
        ticker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        do {
            try await recording.stop()
            captions.engineEnded()
            finalize(recording.directory, id: recording.id, showWhenReady: true)
        } catch {
            banner = "結束錄音時發生錯誤：\(error)。已經錄下的聲音還在，下次開啟 App 時會自動復原。"
        }
        self.recording = nil
        level = 0
        liveState = .idle
    }

    func togglePause() {
        guard let recording else { return }
        if recording.isPaused {
            recording.resume()
            liveState = .recording
        } else {
            recording.pause()
            liveState = .paused
        }
    }

    func mark() {
        recording?.mark()
    }

    private var captureSource: CaptureSource {
        switch source {
        case .system: .systemAudio
        case .microphone(let uid): .microphone(deviceUID: uid.isEmpty ? nil : uid)
        case .file(let url): .file(url)
        }
    }

    /// 每 0.25 秒更新一次時間與音量，並檢查裝置是不是還在送聲音。只在錄音中執行。
    private func startTicker() {
        lastCallbackCount = 0
        silentTicks = 0
        quietTicks = 0
        heardSound = false
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let recording = self.recording else { return }
                self.elapsed = recording.audioTime.seconds
                self.level = recording.level
                if case .file = self.source { continue }
                let count = recording.captureCallbackCount
                self.silentTicks = count == self.lastCallbackCount ? self.silentTicks + 1 : 0
                self.lastCallbackCount = count
                if self.silentTicks == 12 {
                    self.banner = "超過 3 秒沒有收到任何聲音。裝置可能被拔掉了，或是沒有權限。已經錄下的部分不受影響。"
                }
                // 裝置有在送資料，但全部是靜音：最常見的原因是沒有權限（系統只會給靜音，不會回報錯誤）
                if recording.level > 0.000_5 {
                    self.heardSound = true
                    self.quietTicks = 0
                } else if !recording.isPaused {
                    self.quietTicks += 1
                }
                if self.quietTicks == 24, !self.heardSound {
                    self.banner =
                        self.source == .system
                        ? "開始 6 秒了，還沒有偵測到任何聲音。如果電腦正在播放聲音，請到「系統設定 → 隱私權與安全性」，在錄製系統音訊的項目裡允許 ThunderFlow，然後停止再重新開始。"
                        : "開始 6 秒了，還沒有偵測到任何聲音。請確認選對了麥克風、沒有靜音，而且「系統設定 → 隱私權與安全性 → 麥克風」已經允許 ThunderFlow。"
                }
            }
        }
    }

    private static func prompt(title: String, event: String, speaker: String) -> String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("Title: \(title).") }
        if !event.isEmpty { parts.append("Event: \(event).") }
        if !speaker.isEmpty { parts.append("Speaker: \(speaker).") }
        return parts.joined(separator: " ")
    }

    private static func freeSpace(at url: URL) -> Int64? {
        let existing = url.deletingLastPathComponent().deletingLastPathComponent()
        return try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: 結束處理與清單

    private func finalizer() -> SessionFinalizer {
        var options = FinalizationOptions(libraryRoot: settings.libraryRoot)
        options.summarize = settings.autoSummary
        options.summaryModel = settings.postTextModel
        if settings.hasKey, let key = Credentials.load(), !key.isEmpty {
            options.textModel = OpenAITextModel(apiKey: key, baseURL: settings.textBaseURL)
        }
        return SessionFinalizer(options: options)
    }

    /// 在背景把一場做完：段落、逐字稿、m4a、搬進資料夾、摘要。不擋下一場錄音。
    func finalize(_ directory: SessionDirectory, id: UUID, showWhenReady: Bool) {
        processing[id] = "處理中"
        let finalizer = finalizer()
        Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do {
                try await finalizer.finalize(directory) { step, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.processing[id] = Self.label(for: step)
                        // 搬進資料夾之後，逐字稿就可以讀了：這時把畫面帶到這一場
                        if step == .publish {
                            self.reloadLibrary()
                            if showWhenReady, !self.isRecording {
                                self.selectedSession = id
                                self.page = .library
                            }
                        }
                    }
                }
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                guard let self else { return }
                self.processing[id] = nil
                if let failure { self.banner = "這一場的結束處理沒有完成：\(failure)。錄音還在，下次開啟 App 時會再試一次。" }
                self.reloadLibrary()
            }
        }
    }

    private static func label(for step: FinalizationStep) -> String {
        switch step {
        case .blocks, .transcript: "合併錄音中"
        case .audio: "整理資料夾中"
        case .publish: "產生摘要中"
        case .summary: "完成"
        }
    }

    func reloadLibrary() {
        let root = settings.libraryRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = SessionLibrary.list(root: root)
            await MainActor.run { self?.sessions = items }
        }
    }

    /// 上次沒有正常結束的場次：錄音中被中斷的先復原，再把沒做完的結束處理接著做完。
    private func resumeUnfinished() {
        let working = settings.workingRoot
        let library = settings.libraryRoot
        Task.detached(priority: .utility) { [weak self] in
            for interrupted in (try? SessionRecovery.findInterrupted(in: working)) ?? [] {
                _ = try? SessionRecovery.recover(interrupted)
            }
            var pending: [(SessionDirectory, UUID)] = []
            let names = (try? FileManager.default.contentsOfDirectory(atPath: working.path)) ?? []
            for name in names {
                let directory = SessionDirectory(url: working.appendingPathComponent(name, isDirectory: true))
                if let meta = try? directory.loadMeta(), meta.state == .finalizing { pending.append((directory, meta.id)) }
            }
            for item in SessionLibrary.list(root: library) where item.meta.state == .finalizing {
                pending.append((item.directory, item.meta.id))
            }
            let found = pending
            await MainActor.run {
                guard let self else { return }
                for (directory, id) in found where self.processing[id] == nil {
                    self.finalize(directory, id: id, showWhenReady: false)
                }
            }
        }
    }

    func regenerateSummary(_ item: SessionLibrary.Item) {
        processing[item.id] = "產生摘要中"
        let finalizer = finalizer()
        Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do { try await finalizer.regenerateSummary(item.directory) } catch { failure = "\(error)" }
            await MainActor.run {
                self?.processing[item.id] = nil
                if let failure { self?.banner = "摘要沒有產生成功：\(failure)" }
                self?.reloadLibrary()
            }
        }
    }

    func delete(_ item: SessionLibrary.Item) {
        NSWorkspace.shared.recycle([item.directory.url]) { [weak self] _, _ in
            Task { @MainActor in
                if self?.selectedSession == item.id { self?.selectedSession = nil }
                self?.reloadLibrary()
            }
        }
    }

    var filteredSessions: [SessionLibrary.Item] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.meta.title.localizedCaseInsensitiveContains(query) || $0.meta.oneLiner.localizedCaseInsensitiveContains(query)
                || $0.meta.event.localizedCaseInsensitiveContains(query)
        }
    }
}

enum Permissions {
    /// 麥克風的權限。還沒問過就問一次。
    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
