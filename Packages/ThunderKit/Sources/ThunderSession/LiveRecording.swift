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
///
/// 收音可以中途換掉（DESIGN.md 2.3 節第 9 條、5.4 節）：裝置不見、睡眠醒來、換了輸出裝置時，
/// `resumeCapture(reason:)` 建立新的來源接著錄同一場；電腦要睡了時先 `suspendCapture()`。
public final class LiveRecording: @unchecked Sendable {
    // @unchecked Sendable：`session` 在 `start()` 裡設定一次，之後不再改變。
    // `start`、`stop`、`suspendCapture`、`resumeCapture` 由 `operation` 依序執行（裡面會等 Core Audio）；
    // 目前的收音與累計的計數在 `state` 裡，屬性從別的執行緒讀，只短暫持有。其餘是常數或本身可以跨執行緒使用的物件。
    public struct Options: Sendable {
        public var source: CaptureSource
        public var title = ""
        public var event = ""
        public var speaker = ""
        public var keywords: [String] = []
        /// 引擎的名稱，記在 `session.json`。
        public var engineName = ""
        /// 開始時有沒有開暫定譯文，記在 `session.json`（估算費用用）。nil 時不記。
        public var provisionalTranslation: Bool?
        /// 工作目錄：錄音中的場次資料夾放在這裡。
        public var workingRoot: URL
        /// 結束時最多等引擎把最後幾段翻完多久。
        public var engineDrainTimeout: Duration = .seconds(10)

        public init(source: CaptureSource, workingRoot: URL) {
            self.source = source
            self.workingRoot = workingRoot
        }
    }

    /// 建立收音來源的方法。App 用預設的（真正的裝置）；測試換成假的來源。
    public typealias CaptureFactory = @Sendable (CaptureSource, RingBuffer) -> any AudioCapturing

    public let id = UUID()
    public let directory: SessionDirectory
    public let startedAt = Date()
    private let options: Options
    private let engine: any LiveCaptionEngine
    private let ring: RingBuffer
    private let makeCapture: CaptureFactory
    private var session: RecordingSession?
    private let meter = LevelMeter()
    private let operation = NSLock()
    private let state: Mutex<CaptureState>

    private struct CaptureState {
        var capture: any AudioCapturing
        var pump: Pump?
        var converter: ConverterBox?
        /// 收音中斷（`suspendCapture()`，或重新開始失敗）從什麼時候開始；收音中是 nil。
        var interruptedAt: ContinuousClock.Instant?
        /// 這一場開始時的取樣率：錄音檔、音訊時間與送給引擎的音訊都以它為準。
        var sessionRate: Double = 0
        /// 已經換掉的來源合計的 callback 次數與不連續次數。
        var pastCallbacks = 0
        var pastDiscontinuities = 0
        var firstSample: UInt64?
        /// `stop()` 之後不再重新開始收音（裝置的變化可能和停止同時發生）。
        var finished = false
    }

    /// - Parameters:
    ///   - makeCapture: 建立收音來源的方法。開始時建立一次，之後每次 `resumeCapture` 再建立一個新的。
    ///   - onEvent: 引擎的每一個事件（英文、中文、狀態……）。在引擎的 task 上被呼叫，必須立即返回。
    public init(
        options: Options, engine: any LiveCaptionEngine,
        makeCapture: @escaping CaptureFactory = { AudioCapture(source: $0, ring: $1) },
        onEvent: @escaping @Sendable (CaptionEvent) -> Void
    ) {
        self.options = options
        self.engine = ObservedEngine(engine, onEvent: onEvent)
        directory = SessionDirectory(url: options.workingRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        // 至少放得下 10 秒：到 96 kHz 都夠用
        let ring = RingBuffer(minimumCapacity: 1 << 20)
        self.ring = ring
        self.makeCapture = makeCapture
        state = Mutex(CaptureState(capture: makeCapture(options.source, ring)))
    }

    /// 來源的說明，例如裝置名稱或「系統音訊」。開始之後才有值；重新開始收音之後是新的來源。
    public var sourceDescription: String { state.withLock { $0.capture.sourceDescription } }

    /// 收音的來源和使用者選的不一樣時給使用者的說明：記住的麥克風不在了，改用系統預設的
    /// （說用了哪一個）。開始之後才有值；照選的開始時是 nil。
    public var captureNotice: String? { state.withLock { $0.capture.notice } }

    /// 收音用的裝置（麥克風的 UID，或系統音訊開始時的預設輸出裝置的 UID）。用來判斷裝置是不是不見了。
    public var captureDeviceUID: String? { state.withLock { $0.capture.deviceUID } }

    /// 收音中斷中（`suspendCapture()` 之後、或重新開始失敗），還沒有接著錄。
    public var isCaptureInterrupted: Bool { state.withLock { $0.interruptedAt != nil } }

    /// 來源自己結束了（音檔播完）。在別的執行緒上被呼叫。要在 `start()` 之前設定。
    public var onSourceEnded: (@Sendable () -> Void)? {
        get { state.withLock { $0.capture.onEnded } }
        set { state.withLock { $0.capture.onEnded = newValue } }
    }

    /// 開始收音、錄音與字幕。失敗時（找不到裝置、磁碟寫不進去）丟出錯誤，不留下收音中的裝置。
    public func start() throws {
        try operation.withLock {
            guard session == nil else { return }
            let capture = state.withLock { $0.capture }
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
                config.provisionalTranslation = options.provisionalTranslation
                config.engineDrainTimeout = options.engineDrainTimeout
                let session = try RecordingSession(config: config, directory: directory, engine: engine)
                let pump = makePump(for: session, converter: nil)
                self.session = session
                state.withLock {
                    $0.pump = pump
                    $0.sessionRate = sampleRate
                }
                session.start()
                pump.start()
            } catch {
                capture.stop()
                throw error
            }
        }
    }

    public var audioTime: AudioTime { session?.audioTime ?? .zero }
    public var isPaused: Bool { session?.isPaused ?? false }

    /// 最近的音量（峰值，0–1），給音量表用。
    public var level: Float { Float(bitPattern: meter.bits.load(ordering: .relaxed)) }

    /// 錄音檔寫不進去（例如磁碟滿了）而沒有錄到的長度（秒）。大於 0 時畫面要提醒使用者。
    public var unrecordedSeconds: Double { session?.unrecordedSeconds ?? 0 }

    /// 裝置的 callback 到目前為止被呼叫了幾次（重新開始收音之前的來源也算在內）。一直沒有增加，代表沒有收到聲音。
    public var captureCallbackCount: Int { state.withLock { $0.pastCallbacks + $0.capture.callbackCount } }

    /// 裝置第一次送來樣本的時間（`CLOCK_UPTIME_RAW` 的奈秒）。音檔來源不經過裝置，一直是 nil。
    public var firstSampleUptimeNanoseconds: UInt64? {
        state.withLock { $0.firstSample ?? $0.capture.firstSampleUptimeNanoseconds }
    }

    public func pause() { session?.pause() }
    public func resume() { session?.resume() }
    public func mark() { session?.mark() }

    /// 收音要中斷了（電腦要睡了）：停止收音，把已經收到的聲音錄完，記下中斷開始的時間。
    /// 之後呼叫 `resumeCapture(reason:)` 接著錄同一場。中斷期間場次照常：可以暫停、標記或停止。
    /// 還沒開始、或已經中斷時不做任何事。
    public func suspendCapture() {
        operation.withLock {
            guard session != nil, state.withLock({ $0.interruptedAt == nil && !$0.finished }) else { return }
            stopCapture()
            state.withLock { $0.interruptedAt = .now }
        }
    }

    /// 重新開始收音，接著錄同一場（DESIGN.md 2.3 節第 9 條、5.4 節）。
    ///
    /// 停掉原本的收音（如果還在），把收到的聲音錄完，再用同樣的來源設定建立新的來源：
    /// 麥克風不在了就改用系統預設的，系統音訊用現在的預設輸出裝置。新的取樣率不同時，轉成這一場的取樣率再錄。
    /// 日誌在中斷的位置記一筆中斷（`reason`、沒有錄到多久），錄音檔從這裡開新的分段。
    ///
    /// - Parameters:
    ///   - reason: 為什麼中斷（`sleep`、`deviceLost`、`outputChanged`、`captureStalled`）。
    ///   - since: 中斷從什麼時候開始（例如最後一次收到聲音的時間）。nil 時用 `suspendCapture()` 的時間，沒有就是現在。
    /// - Throws: 重新開始收音失敗（例如一個收音裝置都沒有）：場次照常，維持中斷中，之後可以再呼叫一次，或停止。
    ///   已經停止之後呼叫丟出 `RecordingSessionError.alreadyFinished`，不會再開始收音。
    public func resumeCapture(reason: GapReason, since: ContinuousClock.Instant? = nil) throws {
        try operation.withLock {
            guard let session, !state.withLock({ $0.finished }) else { throw RecordingSessionError.alreadyFinished }
            let interruptedAt = since ?? state.withLock { $0.interruptedAt } ?? .now
            stopCapture()
            // 換掉的來源的計數併進累計；重新開始失敗時維持中斷中，下次從原本中斷的時間算起
            state.withLock { current in
                current.pastCallbacks += current.capture.callbackCount
                current.pastDiscontinuities += current.capture.discontinuityCount
                current.firstSample = current.firstSample ?? current.capture.firstSampleUptimeNanoseconds
                current.interruptedAt = interruptedAt
            }
            let capture = makeCapture(options.source, ring)
            state.withLock { $0.capture = capture }
            let rate = try capture.start()
            let sessionRate = state.withLock { $0.sessionRate }
            let converter: ConverterBox?
            do {
                converter = rate == sessionRate ? nil : ConverterBox(try SampleRateConverter(from: rate, to: sessionRate))
            } catch {
                capture.stop()
                throw error
            }
            // 中斷之前的聲音都錄完了（stopCapture），在這裡記下中斷、開新的分段，再開始收新的聲音
            session.recordInterruption(reason: reason, lostSeconds: (ContinuousClock.now - interruptedAt) / .seconds(1))
            let pump = makePump(for: session, converter: converter)
            state.withLock { current in
                current.pump = pump
                current.converter = converter
                current.interruptedAt = nil
            }
            pump.start()
        }
    }

    /// 結束：停止收音，把剩下的樣本錄完，等引擎收尾，並把完整性計數寫進 `session.json`。
    /// 回傳時場次的狀態是 finalizing，可以交給結束處理。收音中斷中也可以結束。
    @discardableResult
    public func stop() async throws -> SessionMeta {
        let counts = operation.withLock { () -> (ringDropped: Int, discontinuities: Int) in
            state.withLock { $0.finished = true }
            stopCapture()
            return (ring.droppedSampleCount, state.withLock { $0.pastDiscontinuities + $0.capture.discontinuityCount })
        }
        guard let session else { throw RecordingSessionError.alreadyFinished }
        // 收音已經停了，收音端的計數不會再變：交給場次，和其他計數一起在交出場次的鎖之前寫進 session.json。
        // 交出鎖之後就不能再寫：另一個程式的結束處理可能已經拿到鎖，會蓋掉它的紀錄
        return try await session.finish(
            ringDroppedSamples: counts.ringDropped, captureDiscontinuities: counts.discontinuities)
    }

    // MARK: 收音（持有 `operation`）

    /// 停止目前的收音，把 RingBuffer 裡剩下的樣本錄完（取樣率轉換器裡剩下的也是）。已經停了就不做任何事。
    private func stopCapture() {
        let (capture, pump, converter) = state.withLock { current in
            defer {
                current.pump = nil
                current.converter = nil
            }
            return (current.capture, current.pump, current.converter)
        }
        capture.stop()
        pump?.stop()
        if let converter, let session { try? converter.value.finish { try? session.process($0) } }
    }

    /// 把 RingBuffer 裡的樣本交給場次；`converter` 不是 nil 時先轉成這一場的取樣率。
    private func makePump(for session: RecordingSession, converter: ConverterBox?) -> Pump {
        let meter = meter
        return Pump(ring: ring) { samples in
            // 寫不進錄音檔的聲音由場次記帳（`unrecordedSeconds`），這裡不用再處理
            if let converter {
                try? converter.value.convert(samples) { try? session.process($0) }
            } else {
                try? session.process(samples)
            }
            var peak: Float = 0
            for sample in samples { peak = max(peak, abs(sample)) }
            meter.bits.store(peak.bitPattern, ordering: .relaxed)
        }
    }
}

/// 取樣率轉換器。只在一條執行緒上使用：收音中是 Pump 的執行緒，Pump 停了之後才由停止收音的那一方收尾。
private final class ConverterBox: @unchecked Sendable {
    let value: SampleRateConverter

    init(_ value: SampleRateConverter) {
        self.value = value
    }
}

/// 最近一批樣本的音量（峰值，0–1）的位元表示。Pump 的執行緒寫，畫面讀。
private final class LevelMeter: Sendable {
    let bits = Atomic<UInt32>(0)
}
