import AVFoundation
import Foundation
import Observation
import ThunderCore
import ThunderSession
import ThunderUI

/// 過去錄音（DESIGN.md 5.10 節，D38）：Mac 放在 App 自己的 iCloud 空間裡的 Library。手機上只能看，不能改
/// （改名、刪除、重新產生摘要、教材都在 Mac 上）。
///
/// 清單只下載每一場的 `session.json`（小檔）；打開一場才下載逐字稿與摘要，按播放才下載錄音。
/// 列出場次、讀檔的規則和 Mac 一樣（ThunderKit 的 `SessionLibrary`、`TranscriptBlocks`、`SessionSummary`）。
@MainActor
@Observable
final class PhoneLibrary {
    private(set) var items: [SessionLibrary.Item] = []
    /// 第一次讀（清單還是空的）時顯示讀取中。
    private(set) var loading = false
    /// 還沒從 iCloud 下載下來的場次數（例如沒有網路）。
    private(set) var pending = 0
    /// 讀不到時的說明（例如 iCloud 不能用）。
    private(set) var problem: String?

    @ObservationIgnored private var refreshing = false

    static let unavailable = "這支 iPhone 沒有登入 iCloud，或關掉了 iCloud 雲碟：看不到 Mac 上的過去錄音。"

    /// Library 的位置：App 自己的 iCloud 空間裡的 `Documents/`（Mac 寫進去，D38）。iCloud 不能用時是 nil。
    /// 自動測試用 `-selfTestLibrary <資料夾>` 換成別的資料夾（模擬器沒有 iCloud）。會等待，不要在主執行緒上呼叫。
    nonisolated static func location() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "selfTestLibrary") { return URL(fileURLWithPath: path, isDirectory: true) }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: SessionHandoff.containerIdentifier)
        else { return nil }
        return SessionHandoff.library(inContainer: container)
    }

    /// 重新讀清單：先列出已經在手機上的，再把還沒下載的 `session.json` 下載下來、再列一次。
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        if items.isEmpty { loading = true }
        defer {
            refreshing = false
            loading = false
        }
        guard let root = await ICloudFiles.run({ Self.location() }) else {
            problem = Self.unavailable
            items = []
            pending = 0
            return
        }
        problem = nil
        let (local, folders) = await ICloudFiles.run { (SessionLibrary.list(root: root), Self.folders(in: root)) }
        items = local
        let listed = Set(local.map { $0.directory.url.standardizedFileURL })
        let missing = folders.filter { !listed.contains($0.standardizedFileURL) }
        guard !missing.isEmpty else {
            pending = 0
            return
        }
        let timedOut = await ICloudFiles.run { () -> Int in
            let metas = missing.map { SessionDirectory(url: $0).metaURL }
            metas.forEach(ICloudFiles.requestDownload)
            // 系統同時在下載：一個一個等，總共大約是最慢的那一個的時間
            return metas.filter { ICloudFiles.download($0, timeout: 20) == .timedOut }.count
        }
        items = await ICloudFiles.run { SessionLibrary.list(root: root) }
        pending = timedOut
    }

    /// Library 底下一層的資料夾（名稱以「.」開頭的不算）。
    nonisolated private static func folders(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
    }

    func item(at folder: URL) -> SessionLibrary.Item? {
        items.first { $0.directory.url.standardizedFileURL == folder.standardizedFileURL }
    }
}

/// 一場的詳細內容：逐字稿與摘要（打開時才從 iCloud 下載）。
@MainActor
@Observable
final class PhoneSessionDetail {
    let item: SessionLibrary.Item
    private(set) var blocks: [TranscriptBlock] = []
    private(set) var summary: SessionSummary?
    private(set) var loading = true
    private(set) var problem: String?
    /// 分頁：只在第一次讀到內容時決定先看哪一頁（判斷在 ThunderUI，和 Mac 一樣）。
    var tabs = SessionDetailTabs()

    init(item: SessionLibrary.Item) {
        self.item = item
    }

    func load() async {
        let directory = item.directory
        let steps = item.meta.completedSteps
        let wantsBlocks = steps.contains(FinalizationStep.blocks.rawValue)
        let wantsSummary = steps.contains(FinalizationStep.summary.rawValue)
        let loaded = await ICloudFiles.run { () -> ([TranscriptBlock], SessionSummary?, String?) in
            if wantsBlocks { ICloudFiles.requestDownload(directory.blocksURL) }
            if wantsSummary { ICloudFiles.requestDownload(directory.summaryDataURL) }
            var problem: String?
            if wantsBlocks, ICloudFiles.download(directory.blocksURL, timeout: 30) == .timedOut {
                problem = "逐字稿還沒從 iCloud 下載下來（沒有網路？），稍後再打開一次。"
            }
            if wantsSummary { _ = ICloudFiles.download(directory.summaryDataURL, timeout: 30) }
            let blocks = (try? TranscriptBlocks.read(directory.blocksURL)) ?? []
            let summary = try? SessionSummary.read(directory.summaryDataURL)
            return (blocks, summary, problem)
        }
        (blocks, summary, problem) = loaded
        tabs.contentLoaded(hasSummary: summary != nil)
        loading = false
    }
}

/// 錄音的播放：按播放時才從 iCloud 下載。播放、暫停、拖曳、前後跳 15 秒。
///
/// 錄音中不能播放（麥克風占著音訊；畫面會先擋下）。只在自己打開了音訊時才關掉它，不會關到錄音用的音訊。
@MainActor
@Observable
final class PhonePlayer {
    enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isPlaying = false
    var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activatedSession = false

    /// 下載錄音、準備播放；準備好就開始播。
    func prepareAndPlay(_ url: URL) async {
        switch state {
        case .downloading: return
        case .ready:
            toggle()
            return
        case .idle, .failed: break
        }
        state = .downloading
        let outcome = await ICloudFiles.run { ICloudFiles.download(url, timeout: 600) }
        guard outcome == .ready, let player = try? AVAudioPlayer(contentsOf: url) else {
            state = .failed(outcome == .timedOut ? "錄音還沒下載下來（沒有網路？），再按一次重試。" : "這一場的錄音打不開。")
            return
        }
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        state = .ready
        toggle()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            activate()
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    /// 跳到 `seconds`；`play` 時沒在播放就開始播（點章節、段落），拖曳進度列時不會。
    func seek(to seconds: TimeInterval, play: Bool = true) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), max(0, duration - 0.1))
        position = player.currentTime
        if play, !player.isPlaying { toggle() }
    }

    func skip(_ seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, position + seconds), max(0, duration - 0.1))
        position = player.currentTime
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
        if activatedSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedSession = false
        }
    }

    private func activate() {
        guard !activatedSession else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        activatedSession = true
    }

    /// 只在播放中更新位置；暫停時不留計時器。
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}
