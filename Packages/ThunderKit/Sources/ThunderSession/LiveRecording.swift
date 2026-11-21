import Foundation
import Synchronization
import ThunderAudio
import ThunderCore

/// 一場進行中的錄音：把收音、錄音路徑（RingBuffer、Pump、RecordingSession）與引擎組在一起。
///
/// 畫面只和它打交道，不直接碰 Core Audio 或引擎。這裡只做組裝，不放判斷：
/// 收音在 `AudioCapture`，錄音與字幕的規則在 `RecordingSession`，連線與翻譯在引擎裡。
///
/// 順序：`start()` 先開始收音（聲音立刻進 RingBuffer），再建立場次與 Pump，所以按下開始之後的聲音一個不少；
/// 引擎連線需要的那幾百毫秒，音訊在等待區裡等它。
public final class LiveRecording: @unchecked Sendable {
    // @unchecked Sendable：`session`、`pump`、`sampleRate` 在 `start()` 裡設定一次，之後不再改變；
    // `start`、`stop` 由呼叫端（畫面，主執行緒）依序呼叫。其餘是常數或本身可以跨執行緒使用的物件。
    public struct Options: Sendable {
        public var source: CaptureSource
        public var title = ""
        public var event = ""
        public var speaker = ""
        public var keywords: [String] = []
        /// 引擎的名稱，記在 `session.json`。
        public var engineName = ""
        /// 工作目錄：錄音中的場次資料夾放在這裡。
        public var workingRoot: URL
        /// 結束時最多等引擎把最後幾段翻完多久。
        public var engineDrainTimeout: Duration = .seconds(10)

        public init(source: CaptureSource, workingRoot: URL) {
            self.source = source
            self.workingRoot = workingRoot
        }
    }

    public let id = UUID()
    public let directory: SessionDirectory
    public let startedAt = Date()
    private let options: Options
    private let engine: any LiveCaptionEngine
    private let ring: RingBuffer
    private let capture: AudioCapture
    private var session: RecordingSession?
    private var pump: Pump?
    private let meter = LevelMeter()

    /// - Parameter onEvent: 引擎的每一個事件（英文、中文、狀態……）。在引擎的 task 上被呼叫，必須立即返回。
    public init(options: Options, engine: any LiveCaptionEngine, onEvent: @escaping @Sendable (CaptionEvent) -> Void) {
        self.options = options
        self.engine = ObservedEngine(engine, onEvent: onEvent)
        directory = SessionDirectory(url: options.workingRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        // 至少放得下 10 秒：到 96 kHz 都夠用
        ring = RingBuffer(minimumCapacity: 1 << 20)
        capture = AudioCapture(source: options.source, ring: ring)
    }

    /// 來源的說明，例如裝置名稱或「系統音訊」。開始之後才有值。
    public var sourceDescription: String { capture.sourceDescription }

    /// 來源自己結束了（音檔播完）。在別的執行緒上被呼叫。要在 `start()` 之前設定。
    public var onSourceEnded: (@Sendable () -> Void)? {
        get { capture.onEnded }
        set { capture.onEnded = newValue }
    }

    /// 開始收音、錄音與字幕。失敗時（找不到裝置、磁碟寫不進去）丟出錯誤，不留下收音中的裝置。
    public func start() throws {
        guard session == nil else { return }
        let sampleRate = try capture.start()
        do {
            var config = SessionConfig(sampleRate: sampleRate)
            config.id = id
            config.title = options.title
            config.event = options.event
            config.speaker = options.speaker
            config.keywords = options.keywords
            config.startedAt = startedAt
            config.source = capture.sourceDescription
            config.engineName = options.engineName
            config.engineDrainTimeout = options.engineDrainTimeout
            let session = try RecordingSession(config: config, directory: directory, engine: engine)
            let meter = meter
            let pump = Pump(ring: ring) { samples in
                try? session.process(samples)
                var peak: Float = 0
                for sample in samples { peak = max(peak, abs(sample)) }
                meter.bits.store(peak.bitPattern, ordering: .relaxed)
            }
            self.session = session
            self.pump = pump
            session.start()
            pump.start()
        } catch {
            capture.stop()
            throw error
        }
    }

    public var audioTime: AudioTime { session?.audioTime ?? .zero }
    public var isPaused: Bool { session?.isPaused ?? false }

    /// 最近的音量（峰值，0–1），給音量表用。
    public var level: Float { Float(bitPattern: meter.bits.load(ordering: .relaxed)) }

    /// 裝置的 callback 到目前為止被呼叫了幾次。一直沒有增加，代表沒有收到聲音。
    public var captureCallbackCount: Int { capture.mixer.callbackCount }

    public func pause() { session?.pause() }
    public func resume() { session?.resume() }
    public func mark() { session?.mark() }

    /// 結束：停止收音，把剩下的樣本錄完，等引擎收尾，並把完整性計數寫進 `session.json`。
    /// 回傳時場次的狀態是 finalizing，可以交給結束處理。
    @discardableResult
    public func stop() async throws -> SessionMeta {
        capture.stop()
        pump?.stop()
        guard let session else { throw RecordingSessionError.alreadyFinished }
        var meta = try await session.finish()
        meta.integrity.ringDroppedSamples = ring.droppedSampleCount
        meta.integrity.captureDiscontinuities = capture.mixer.discontinuityCount
        try directory.saveMeta(meta)
        return meta
    }
}

/// 最近一批樣本的音量（峰值，0–1）的位元表示。Pump 的執行緒寫，畫面讀。
private final class LevelMeter: Sendable {
    let bits = Atomic<UInt32>(0)
}
