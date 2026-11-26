import AVFoundation
import Foundation
import Observation
import SwiftUI
import ThunderAudio
import ThunderCore
import ThunderEngines
import ThunderSession
import ThunderUI
import UIKit

/// iPhone 版的狀態（DESIGN.md 5.10 節，D36）：開始、停止、標記、即時字幕，被來電打斷之後接著錄同一場，
/// 停止之後把這一場交給 Mac。
///
/// 這裡只做組裝：錄音、字幕與結束處理的規則都在 ThunderKit（和 Mac 同一份程式碼）。
@MainActor
@Observable
final class PhoneModel {
    enum Phase { case idle, starting, recording, stopping }

    private(set) var phase: Phase = .idle
    let captions = LiveCaptionModel()
    /// 標記過重點的字幕行（段號）：那一行後面有一面旗子。
    private(set) var markedLines: Set<Int> = []
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    /// 收音被打斷中（來電、Siri、別的 App 用了麥克風），還沒有接著錄。
    private(set) var interrupted = false
    var banner: String?
    var showsSettings = false
    var showsHandoffs = false
    /// 雙語：中文下面再顯示英文。預設只顯示中文（字大）。
    var bilingual: Bool { didSet { UserDefaults.standard.set(bilingual, forKey: "bilingual") } }
    private(set) var hasKey = false
    let handoff = PhoneHandoff()

    @ObservationIgnored private var recording: LiveRecording?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var resuming = false
    @ObservationIgnored private var foreground = true
    /// 自動測試用：只放在記憶體裡的 Key（`-apiKeyFIFO <路徑>`），有值時完全不碰 Keychain。
    @ObservationIgnored private var keyOverride: String?
    /// 自動測試用：用音檔當來源（`-selfTestFile <路徑>`）。
    @ObservationIgnored private var testSource: CaptureSource?

    nonisolated static let keyAccount = "openai-api-key"
    nonisolated static let keychain = KeychainStore(service: "io.github.ruan330.thunderflow")

    init() {
        bilingual = UserDefaults.standard.bool(forKey: "bilingual")
        observeAudioSession()
    }

    var isRecording: Bool { phase == .recording }

    // MARK: 開始、停止、標記

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        banner = nil
        guard let key = await loadKey() else {
            phase = .idle
            banner = "還沒有設定 OpenAI API Key。請到設定貼上 Key，再按開始。"
            showsSettings = true
            return
        }
        let source = testSource ?? .microphone(deviceUID: nil)
        if case .microphone = source, !(await AVAudioApplication.requestRecordPermission()) {
            phase = .idle
            banner = "沒有麥克風的權限，所以沒有開始錄音。請到「設定 → 隱私權與安全性 → 麥克風」打開 ThunderFlow。"
            return
        }

        captions.reset()
        markedLines = []
        elapsed = 0
        let engine = TranscribeTranslateEngine(
            configuration: Self.engineConfiguration(), apiKey: key,
            textModel: OpenAITextModel(apiKey: key, baseURL: Self.textBaseURL))
        var options = LiveRecording.Options(source: source, workingRoot: PhoneHandoff.workingRoot)
        options.engineName = "gpt-live-transcribe＋gpt-6-luna"
        options.provisionalTranslation = true
        let captions = captions
        let recording = LiveRecording(options: options, engine: engine) { captions.receive($0) }
        recording.onSourceEnded = { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        do {
            // 啟用音訊工作階段、建立收音元件都會等待：在背景做，畫面不會卡住
            try await Task.detached(priority: .userInitiated) { try recording.start() }.value
        } catch {
            banner = "無法開始錄音：\(error)"
            phase = .idle
            return
        }
        self.recording = recording
        interrupted = false
        phase = .recording
        updateIdleTimer()
        startTicker()
    }

    func stop() async {
        guard phase == .recording, let recording else { return }
        phase = .stopping
        ticker?.cancel()
        do {
            _ = try await recording.stop()
        } catch {
            banner = "停止時出了問題（\(error)）。已經錄下的部分都在。"
        }
        captions.engineEnded()
        self.recording = nil
        interrupted = false
        phase = .idle
        updateIdleTimer()
        // 收尾（合併錄音）與交接要幾秒到十幾秒：使用者按完停止就鎖螢幕時，向系統多要一點時間做完；
        // 做不完也沒關係，下次打開或回到 App 時接著做
        let task = BackgroundTask()
        task.begin()
        await handoff.finish(recording.directory)
        task.end()
        if let problem = handoff.problem { banner = problem }
    }

    func mark() {
        guard phase == .recording, let recording else { return }
        recording.mark()
        if let line = captions.board.lines.last?.id { markedLines.insert(line) }
        banner = "已標記 \(Self.timecode(recording.audioTime.seconds))"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Key

    func refreshKeyState() async {
        if keyOverride != nil {
            hasKey = true
            return
        }
        let account = Self.keyAccount
        let stored = await Task.detached { try? Self.keychain.read(account: account) }.value ?? nil
        hasKey = stored?.isEmpty == false
    }

    func saveKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let account = Self.keyAccount
        let saved = await Task.detached { (try? Self.keychain.save(trimmed, account: account)) != nil }.value
        await refreshKeyState()
        return saved
    }

    func deleteKey() async {
        let account = Self.keyAccount
        _ = await Task.detached { try? Self.keychain.delete(account: account) }.value
        await refreshKeyState()
    }

    private func loadKey() async -> String? {
        if let keyOverride { return keyOverride }
        let account = Self.keyAccount
        let stored = await Task.detached { try? Self.keychain.read(account: account) }.value ?? nil
        hasKey = stored?.isEmpty == false
        return hasKey ? stored : nil
    }

    // MARK: 被打斷（來電、Siri、別的 App 用了麥克風）

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw == AVAudioSession.InterruptionType.began.rawValue
                MainActor.assumeIsolated { self?.audioSessionInterrupted(began: began) }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let recording = self.recording, self.phase == .recording else { return }
                    self.interrupted = true
                    Task.detached { recording.suspendCapture() }
                    self.resumeCapture()
                }
            })
    }

    private func audioSessionInterrupted(began: Bool) {
        guard let recording, phase == .recording else { return }
        if began {
            interrupted = true
            // iOS 已經停掉收音：把收到的聲音錄完，記下從什麼時候開始中斷
            Task.detached { recording.suspendCapture() }
            banner = "錄音被打斷了（來電或其他 App 用了麥克風）。打斷結束後會自動接著錄同一場。"
        } else {
            resumeCapture()
        }
    }

    /// 打斷結束（或回到 App 時還在中斷中）：重新開始收音，接著錄同一場。日誌記一筆 `interrupted` 的中斷。
    private func resumeCapture() {
        guard let recording, phase == .recording, !resuming else { return }
        resuming = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<TimeInterval, any Error> in
                Result { try recording.resumeCapture(reason: .interrupted) }
            }.value
            guard let self, self.recording === recording else { return }
            self.resuming = false
            switch result {
            case .success(let lost):
                self.interrupted = false
                self.banner = "已經接著錄同一場（被打斷的 \(Self.duration(lost)) 沒有錄到）。"
            case .failure:
                self.interrupted = true
                self.banner = "還沒辦法接著錄（麥克風可能還在被別的 App 使用）。回到 ThunderFlow 時會再試一次。"
            }
        }
    }

    // MARK: 前景、背景

    func scenePhaseChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        updateIdleTimer()
        guard phase == .active else { return }
        if interrupted, let recording, recording.isCaptureInterrupted { resumeCapture() }
        Task {
            await handoff.processPending()
            showHandoffNotice()
        }
    }

    /// 交接要告訴使用者的事（例如上次的錄音沒有正常結束，已經收尾）顯示成橫幅。
    func showHandoffNotice() {
        guard let notice = handoff.notice else { return }
        banner = notice
        handoff.notice = nil
    }

    /// 錄音中、而且字幕畫面在前景時，螢幕不自動鎖定（DESIGN.md 5.10 節）。不看的時候按側邊鍵鎖螢幕，錄音照常。
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = foreground && phase == .recording
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let recording = self.recording else { return }
                self.elapsed = recording.audioTime.seconds
                self.level = recording.level
            }
        }
    }

    // MARK: 引擎的設定（和 Mac 的預設一樣，DESIGN.md 5.6 節）

    static let textBaseURL = URL(string: "https://api.openai.com/v1")!
    static let realtimeEndpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    static func engineConfiguration() -> TranscribeTranslateEngine.Configuration {
        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.endpoint = realtimeEndpoint
        configuration.link.settings.model = "gpt-live-transcribe"
        configuration.link.settings.delay = "low"
        configuration.translation.model = "gpt-6-luna"
        // 整句重翻與整句的暫定譯文（D32、D33），和 Mac 的預設一樣
        configuration.translation.provisional = true
        configuration.translation.sentences = true
        configuration.translation.sentenceProvisional = true
        configuration.translation.sentenceProvisionalFirstWords = 2
        return configuration
    }

    // MARK: 格式

    /// 01:02:03。
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
    }

    /// 約 N 秒、約 N 分鐘。
    static func duration(_ seconds: Double) -> String {
        seconds < 59.5 ? "約 \(max(1, Int(seconds.rounded()))) 秒" : "約 \(Int((seconds / 60).rounded())) 分鐘"
    }

    // MARK: 自動測試（模擬器）

    /// `-selfTestFile <音檔> -selfTestSeconds 30 -apiKeyFIFO <FIFO> [-selfTestQuit YES]`：
    /// 用音檔跑一整場（開始、中間標記一次、停止、交接），把結果印在標準輸出。Key 從 FIFO 讀進記憶體，不碰 Keychain。
    func runSelfTestIfRequested() async {
        let defaults = UserDefaults.standard
        guard let file = defaults.string(forKey: "selfTestFile") else { return }
        if let fifo = defaults.string(forKey: "apiKeyFIFO") {
            // FIFO 不能用 String(contentsOfFile:)（它照檔案大小讀，FIFO 的大小是 0）：一直讀到寫的那一端關掉為止
            let key = await Task.detached { () -> String? in
                guard let handle = FileHandle(forReadingAtPath: fifo), let data = try? handle.readToEnd() else { return nil }
                return String(decoding: data, as: UTF8.self)
            }.value
            keyOverride = key?.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log("selfTest: key=\(keyOverride?.isEmpty == false ? "received" : "missing")")
        }
        let seconds = max(6, defaults.double(forKey: "selfTestSeconds"))
        testSource = .file(URL(fileURLWithPath: file))
        await start()
        Self.log("selfTest: started=\(phase == .recording) banner=\(banner ?? "-")")
        try? await Task.sleep(for: .seconds(seconds / 2))
        mark()
        try? await Task.sleep(for: .seconds(seconds / 2))
        // 數畫面上真的顯示的中文（整句模式的譯文不在各段的 `chinese` 裡，D32）
        let shown = CaptionZoneSync.paragraphs(
            board: captions.board, marked: markedLines,
            options: CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true))
        let settled = shown.filter { $0.kind == .settled && !$0.text.isEmpty }
        Self.log(
            "selfTest: lines=\(captions.board.lines.count) chinese=\(settled.count) flagged=\(shown.filter(\.flagged).count) audio=\(elapsed)")
        for paragraph in settled.suffix(3) { Self.log("selfTest: zh| \(paragraph.text)") }
        await stop()
        Self.log("selfTest: stopped banner=\(banner ?? "-")")
        for line in handoff.report() { Self.log("selfTest: \(line)") }
        if defaults.bool(forKey: "selfTestQuit") { exit(0) }
    }

    nonisolated static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

/// 向系統多要一點背景時間（按停止之後的收尾與交接）。
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "ThunderFlow 收尾") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
