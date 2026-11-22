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

    var liveState: LiveState = .idle {
        didSet {
            guard liveState != oldValue else { return }
            // 狀態一換，防連點的 0.5 秒就從現在重新起算
            pressGuard.stateChanged(at: .now)
            waitChanged()
        }
    }
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
    /// 裝置有變化（接上、拔掉）就更新 `devices`。第一次列出裝置時建立（`refreshDevices()`）。
    @ObservationIgnored private var deviceWatcher: AudioDeviceWatcher?
    var sourceDescription = ""
    /// 這一場標記過重點的字幕行（段號）：那一行顯示黃色旗子。
    private(set) var markedLines: Set<Int> = []

    // MARK: 提示

    /// 結果看不到的操作做完之後的提示（DESIGN.md 4.10.5 節）。
    private var toasts = ToastState()
    /// 提示上一次重畫的時間：提示到期時更新它，畫面就會在那時把提示收起來。
    private var toastClock = ContinuousClock.now
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?

    // MARK: 等待的提示

    /// 「準備中」「收尾中」的延遲顯示（DESIGN.md 4.10.4）：開始／停止的按鈕與狀態列共用這一個計時，兩邊同時換。
    /// 放在這裡而不是畫面裡，換頁回來時也不會重新起算。
    private var waiting = DelayedIndicator()
    /// 等待的提示上一次重畫的時間：提示該出現時更新它，畫面就會在那時重畫。
    private var waitClock = ContinuousClock.now
    @ObservationIgnored private var waitReveal: Task<Void, Never>?

    /// 延遲顯示的「準備中」（或「收尾中」）是不是已經出現。
    var waitVisible: Bool { waiting.isVisible(at: waitClock) }
    /// 這段等待開始之前的階段（尚未開始、錄音中或已暫停）。
    private var phaseBeforeWait: RecorderPhase = .idle

    /// 畫面上表示的階段：等待未滿 0.3 秒時，按鈕、狀態列與字幕區都維持等待之前的樣子（判斷在 ThunderUI，有測試）。
    var shownPhase: RecorderPhase { recorderPhase.shown(before: phaseBeforeWait, waitVisible: waitVisible) }

    // MARK: 防連點

    /// 開始、暫停、繼續、停止的防連點：狀態剛換的 0.5 秒內不算數（DESIGN.md 4.10.5 節）。
    /// 放在這裡而不是按鈕裡：即時翻譯頁的按鈕和「錄音」選單（快捷鍵）共用同一個。
    @ObservationIgnored private var pressGuard = PressGuard()

    /// 使用者按下開始、暫停、繼續或停止（按鈕、選單或快捷鍵）：狀態剛換的 0.5 秒內不算數。
    func press(_ action: () -> Void) {
        guard pressGuard.accepts(at: .now) else { return }
        action()
    }

    // MARK: 搜尋

    /// ⌘F 要求把游標放進過去錄音的搜尋欄；過去錄音頁放好之後清掉。
    var searchFocusRequested = false

    /// ⌘F（DESIGN.md 4.8 節）：到過去錄音，把游標放進搜尋欄。
    func findInLibrary() {
        page = .library
        searchFocusRequested = true
    }

    private func waitChanged() {
        let now = ContinuousClock.now
        if liveState == .starting || liveState == .stopping {
            waiting.begin(at: now)
        } else {
            waiting.end()
            phaseBeforeWait = recorderPhase
        }
        waitClock = now
        waitReveal?.cancel()
        waitReveal = nil
        guard let revealsAt = waiting.revealsAt, revealsAt > now else { return }
        waitReveal = Task { [weak self] in
            do { try await Task.sleep(until: revealsAt, clock: .continuous) } catch { return }
            self?.waitClock = .now
        }
    }

    // MARK: 過去錄音

    var sessions: [SessionLibrary.Item] = []
    /// 正在做結束處理的場次，以及目前做到哪一步。
    var processing: [UUID: String] = [:]
    var selectedSession: UUID?
    var searchText = ""

    private var recording: LiveRecording?

    /// 自我檢查用：收音的 callback 次數、已經錄下的長度、音量。
    var captureDiagnostics: String {
        guard let recording else { return "no recording" }
        return "callbacks=\(recording.captureCallbackCount) audio=\(recording.audioTime.seconds) level=\(recording.level)"
    }
    private var ticker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var lastCallbackCount = 0
    private var silentTicks = 0
    /// 連續幾次量到的音量都接近零；以及這一場到目前為止有沒有聽到過聲音。
    private var quietTicks = 0
    private var heardSound = false
    /// 錄音中經過的 tick 數（每 0.25 秒一次），用來每 10 秒檢查一次剩餘空間。
    private var ticks = 0
    private var warnedLowDisk = false
    /// 啟動之後的工作做過了沒有：每個程式只做一次。
    private var didStart = false
    /// 只放在記憶體裡的 API Key（自動測試用 `-apiKeyFromStdin YES` 從標準輸入讀進來）。有值時完全不碰鑰匙圈。
    private var keyOverride: String?
    /// 讀過一次的 API Key 留在記憶體裡，之後按開始不再讀鑰匙圈；設定頁存入或刪除 Key 時作廢（`keyChanged()`）。
    @ObservationIgnored private var keyCache = CredentialCache()

    init() {
        let key = UserDefaults.standard.string(forKey: "sourceKey") ?? "system"
        source = key == "system" ? .system : .microphone(uid: key)
    }

    var isRecording: Bool { liveState == .recording || liveState == .paused }

    /// 錄音的階段：狀態的表示與開始／停止的按鈕照它顯示（判斷在 ThunderUI，有測試）。
    var recorderPhase: RecorderPhase {
        switch liveState {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .paused: .paused
        case .stopping: .stopping
        }
    }

    /// 現在要顯示的提示。
    var toast: Toast? { toasts.visible(at: toastClock) }

    /// 顯示一則提示，取代目前的那一則；到期時畫面重畫一次，提示就消失。
    func notify(_ kind: Toast.Kind, _ text: String) {
        let now = ContinuousClock.now
        toasts.post(kind, text, at: now)
        toastClock = now
        toastExpiry?.cancel()
        guard let expiresAt = toasts.expiresAt else { return }
        toastExpiry = Task { [weak self] in
            do { try await Task.sleep(until: expiresAt, clock: .continuous) } catch { return }
            self?.toastClock = .now
        }
    }

    // MARK: 啟動之後

    /// 第一個畫面出現之後才做的事：讀清單、把上次沒做完的場次接著做完。不擋畫面。
    ///
    /// 每個程式只做一次。視窗關掉再打開時不會重做（重做的話，會把上次沒做完的場次再排一次）。
    func didAppear() async {
        guard !didStart else { return }
        didStart = true
        if UserDefaults.standard.bool(forKey: "apiKeyFromStdin") {
            keyOverride = await Task.detached { Self.readKeyFromStandardInput() }.value
        }
        refreshDevices()
        reloadLibrary()
        resumeUnfinished()
        SelfTest.runIfRequested(self)
    }

    /// 重新列出收音裝置。在背景做：程式第一次碰 Core Audio 要等它初始化（實測約 70 ms），
    /// 放在主執行緒上會讓剛出現的畫面卡住（DESIGN.md 9.8 節：第一個畫面前後不在主執行緒上碰 Core Audio）。
    ///
    /// 第一次呼叫時也開始注意裝置的變化：之後接上或拔掉麥克風、AirPods 連上或斷開，清單會自己更新，
    /// 新接上的裝置馬上出現在來源選單裡（不定時喚醒，只有裝置真的改變時才通知）。
    func refreshDevices() {
        let watches = deviceWatcher == nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let devices = AudioDevices.inputDevices()
            let watcher =
                watches
                ? AudioDeviceWatcher { devices in
                    Task { @MainActor in self?.devices = devices }
                } : nil
            await MainActor.run {
                guard let self else { return }
                self.devices = devices
                if let watcher, self.deviceWatcher == nil { self.deviceWatcher = watcher }
            }
        }
    }

    // MARK: 開始與停止

    func start() async {
        guard liveState == .idle else { return }
        PerfProbe.startPressed()
        // 先佔住狀態：等鑰匙圈或麥克風權限的時候再按一次開始，不會建立第二場
        liveState = .starting
        banner = nil
        let key: String
        switch await loadKey() {
        case .found(let found):
            key = found
        case .missing:
            liveState = .idle
            settings.hasKey = false
            banner = "還沒有設定 OpenAI API Key。請到「設定」貼上你的 Key，再回來按開始。"
            page = .settings
            return
        case .denied:
            // Key 還在鑰匙圈裡，只是這次沒有拿到：不說「還沒有設定」，也不跳到設定頁
            liveState = .idle
            banner = "鑰匙圈沒有允許 ThunderFlow 讀取 API Key，所以沒有開始錄音。Key 還在鑰匙圈裡：再按一次「開始錄音」，在鑰匙圈的視窗輸入這台 Mac 的登入密碼，然後按「永遠允許」。"
            return
        case .failed(let error):
            liveState = .idle
            banner = "讀不到鑰匙圈裡的 API Key（\(error)），所以沒有開始錄音。"
            return
        }
        PerfProbe.keyLoaded()
        settings.hasKey = true
        if case .microphone = source, !(await Permissions.microphone()) {
            liveState = .idle
            banner = "沒有麥克風的權限，所以沒有開始錄音。請到「系統設定 → 隱私權與安全性 → 麥克風」打開 ThunderFlow。"
            return
        }

        captions.reset()
        markedLines = []
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
        // 一句說完就整句重翻，取代這一句各段的定稿（DESIGN.md 5.6.2 節）
        configuration.translation.sentences = true
        // 整句的暫定譯文（D33）：每一句 2 個字就送第一個，之後每多 3 個字、至少隔 1 秒
        configuration.translation.sentenceProvisional = true
        configuration.translation.sentenceProvisionalFirstWords = 2
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
            // 建立擷取點、啟動裝置都是會等待的 Core Audio 呼叫：在背景做，畫面不會卡住
            try await Task.detached(priority: .userInitiated) { try recording.start() }.value
        } catch {
            banner = "無法開始錄音：\(error.userFacingDescription)。"
            liveState = .idle
            return
        }
        PerfProbe.captureStarted()
        self.recording = recording
        sourceDescription = recording.sourceDescription
        liveState = .recording
        // 記住的麥克風不在了：已經改用系統預設的開始錄音，說明這一場用了哪一個（DESIGN.md 5.4 節）
        if let notice = recording.captureNotice { banner = notice }
        // 錄音中不讓電腦因為閒置而睡眠
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "錄音中")
        PerfProbe.recordingStarted()
        startTicker()
        warnIfLowOnDisk(during: recording)
    }

    /// 剩餘空間不到 2 GB 時提醒（DESIGN.md 5.5 節）。只是提醒，不影響錄音，所以收音開始之後才在背景算：
    /// 「重要用途可用的空間」要問系統能清掉多少，比較慢，不該算在按下開始到開始收音裡。
    /// 已經有別的橫幅（更晚發生的事）時不蓋掉它。
    private func warnIfLowOnDisk(during recording: LiveRecording) {
        let root = settings.workingRoot
        Task.detached(priority: .utility) { [weak self] in
            guard let free = Self.freeSpace(at: root), free < 2_000_000_000 else { return }
            await MainActor.run {
                guard let self, self.recording === recording, self.banner == nil else { return }
                self.banner = "磁碟剩餘空間不到 2 GB。錄音每小時約需要 350 MB 的暫存空間。"
            }
        }
    }

    /// 結束這一場並交給結束處理。`showingResult` 是 false 時，做完不切換到那一場（例如因為磁碟滿了而自動停止，
    /// 使用者要先看到即時翻譯頁上的說明）。
    func stop(showingResult: Bool = true) async {
        guard let recording, isRecording else { return }
        liveState = .stopping
        ticker?.cancel()
        ticker = nil
        PerfProbe.recordingStopped()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        var failed = false
        do {
            try await recording.stop()
            captions.engineEnded()
            finalize(recording.directory, id: recording.id, showWhenReady: showingResult)
        } catch {
            failed = true
            banner = "結束錄音時發生錯誤：\(error.userFacingDescription)。已經錄下的聲音還在，App 會自動復原這一場。"
        }
        self.recording = nil
        level = 0
        liveState = .idle
        if failed {
            // 錄音的物件放掉之後，場次的鎖才會交出來（見 SessionLock）：等這個函式結束再復原，不用等下次開啟 App
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.resumeUnfinished()
            }
        }
    }

    func togglePause() {
        // 只有錄音中與暫停時（判斷在 ThunderUI，有測試）。收尾中按下去會把狀態改回錄音中，
        // 停止鈕再出現，同一場就可能被停止、做兩次結束處理
        guard let recording, RecordingCommands(phase: recorderPhase).canTogglePause else { return }
        if recording.isPaused {
            recording.resume()
            liveState = .recording
        } else {
            recording.pause()
            liveState = .paused
        }
    }

    /// 標記重點：記進這一場，字幕最新的那一行加上旗子，並用提示說出標記的時間。
    func mark() {
        // 收尾中的那一場不再標記（按下停止後，畫面還維持錄音中的那 0.3 秒內按 ⌘B 也一樣）
        guard let recording, isRecording else { return }
        recording.mark()
        if let line = captions.board.lines.last?.id { markedLines.insert(line) }
        notify(.marked, "已標記 \(Format.timecode(recording.audioTime.seconds))")
    }

    /// 只給字幕區的外觀檢查用（`SelfTest.previewCaptions`）：不錄音，直接標記這幾行。
    func previewMarks(_ lines: Set<Int>) {
        markedLines = lines
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
        ticks = 0
        warnedLowDisk = false
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let recording = self.recording else { return }
                self.elapsed = recording.audioTime.seconds
                self.level = recording.level
                PerfProbe.check(firstSample: recording.firstSampleUptimeNanoseconds)
                // 錄音檔寫不進去（例如磁碟滿了）：停止錄音，已經錄下的部分照常收尾
                if recording.unrecordedSeconds > 0 {
                    self.banner = "錄音檔寫不進去（磁碟可能滿了），所以停止了錄音。已經錄下的部分都保存了，請清出空間再開始。"
                    Task { await self.stop(showingResult: false) }
                    return
                }
                // 每 10 秒看一次剩餘空間：不夠時先提醒；快用完時停止，留下收尾（合併錄音、寫逐字稿）需要的空間
                self.ticks += 1
                if self.ticks % 40 == 0, let free = Self.freeSpace(at: self.settings.workingRoot, important: false) {
                    if free < 500_000_000 {
                        self.banner = "磁碟剩餘空間不到 500 MB，所以停止了錄音。已經錄下的部分都保存了。"
                        Task { await self.stop(showingResult: false) }
                        return
                    }
                    if free < 1_000_000_000, !self.warnedLowDisk {
                        self.warnedLowDisk = true
                        self.banner = "磁碟剩餘空間不到 1 GB（錄音每小時約需要 350 MB）。剩下不到 500 MB 時會自動停止錄音。"
                    }
                }
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

    /// 剩餘空間。`important` 是 true 時包含系統可以清掉的空間（算起來比較慢，只在開始時、在背景用）；
    /// 錄音中定期檢查用 false：只算真的空著的空間，又快又保守。
    nonisolated private static func freeSpace(at url: URL, important: Bool = true) -> Int64? {
        let existing = url.deletingLastPathComponent().deletingLastPathComponent()
        if important {
            return try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
        return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    // MARK: API Key

    /// 讀 API Key 並分類（讀到、沒有、使用者沒有允許、其他錯誤）。
    /// 讀過一次就留在記憶體裡，之後不再讀鑰匙圈（第一次讀可能跳出授權視窗）。
    /// 鑰匙圈可能跳出授權視窗、等使用者回答，所以不在主執行緒上讀，畫面不會卡住。
    func loadKey() async -> CredentialLookup {
        if let keyOverride { return .found(keyOverride) }
        if let key = keyCache.key { return .found(key) }
        let ticket = keyCache.ticket
        let lookup = await Task.detached(priority: .userInitiated) { Credentials.lookup() }.value
        keyCache.remember(lookup, ticket: ticket)
        return lookup
    }

    /// 設定頁存入或刪除了 Key：忘掉記在記憶體裡的 Key，下次按開始重新讀鑰匙圈。
    func keyChanged() {
        keyCache.invalidate()
    }

    /// 自動測試用：從標準輸入讀 Key（`open --stdin <FIFO>` 加上啟動參數 `-apiKeyFromStdin YES`）。
    /// Key 只放在記憶體裡，不寫進鑰匙圈或任何檔案。
    nonisolated private static func readKeyFromStandardInput() -> String? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: 結束處理與清單

    /// `needsModel` 是 false 時（不自動產生摘要）不讀 Key，也就不會因為鑰匙圈跳出授權視窗。
    private func finalizer(needsModel: Bool) async -> SessionFinalizer {
        var options = FinalizationOptions(libraryRoot: settings.libraryRoot)
        options.summarize = settings.autoSummary
        options.summaryModel = settings.postTextModel
        if needsModel, keyOverride != nil || settings.hasKey, case .found(let key) = await loadKey() {
            options.textModel = OpenAITextModel(apiKey: key, baseURL: settings.textBaseURL)
        }
        return SessionFinalizer(options: options)
    }

    /// 在背景把一場做完：段落、逐字稿、m4a、搬進資料夾、摘要。不擋下一場錄音。
    func finalize(_ directory: SessionDirectory, id: UUID, showWhenReady: Bool) {
        processing[id] = "處理中"
        Task { await runFinalization(directory, id: id, showWhenReady: showWhenReady) }
    }

    private func runFinalization(_ directory: SessionDirectory, id: UUID, showWhenReady: Bool) async {
        let finalizer = await finalizer(needsModel: settings.autoSummary)
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
            } catch SessionFinalizerError.inProgress {
                // 另一個 ThunderFlow 正在處理這一場：交給它
            } catch {
                failure = error.userFacingDescription
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
        // 處理中不再開始另一個（選單的按鈕這時也停用）：只會拿不到鎖而失敗，失敗時還會把處理中的標示清掉
        guard SessionActions(progress: processing[item.id]).canRegenerateSummary else { return }
        processing[item.id] = "產生摘要中"
        Task { await runRegeneration(item) }
    }

    private func runRegeneration(_ item: SessionLibrary.Item) async {
        let finalizer = await finalizer(needsModel: true)
        Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do {
                try await finalizer.regenerateSummary(item.directory)
            } catch SessionFinalizerError.inProgress {
                failure = "這一場正在處理中，請等它做完再試一次"
            } catch {
                failure = error.userFacingDescription
            }
            await MainActor.run {
                self?.processing[item.id] = nil
                if let failure { self?.banner = "摘要沒有產生成功：\(failure)。錄音與逐字稿不受影響。" }
                self?.reloadLibrary()
            }
        }
    }

    func delete(_ item: SessionLibrary.Item) {
        // 處理中不刪除（選單的按鈕這時也停用）：結束處理還在寫這個資料夾，搬走會讓它寫到一半
        guard SessionActions(progress: processing[item.id]).canDelete else { return }
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
