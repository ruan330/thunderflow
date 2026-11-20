import Foundation
import Synchronization
import ThunderAudio
import ThunderCore

public enum RecordingSessionError: Error, Equatable {
    /// 場次已經結束，不能再送入音訊。
    case alreadyFinished
}

/// 一場錄音：把音訊寫成分段錄音、轉送給引擎，並把引擎的字幕寫進日誌。
///
/// 最重要的保證：**錄音不受引擎影響**。`process` 是同步的，只做寫檔、轉格式、
/// 把音訊放進引擎的等待區（立即返回）；引擎卡住、變慢、提早結束，都不會讓它等待或遺失樣本。
///
/// 執行緒規則：
/// - `process` 只能由一條執行緒呼叫（Pump）。
/// - `pause`、`resume`、`mark` 與各個屬性可以從任何執行緒呼叫。
///
/// 送給引擎的音訊：
/// - 等待區是 `bufferingNewest` 的 `AsyncStream`，容量是 `engineBufferDuration ÷ engineChunkDuration` 包。
///   放進去一律立即返回；滿了就丟掉最舊的一包，記成原因為 `backpressure` 的缺口。
/// - 引擎的事件串流自己結束之後（例如回報失敗），之後的音訊不再送出，記成原因為 `engineStopped` 的缺口。
/// - 缺口一包記一筆，日誌裡的缺口長度加總就是 `integrity.untranslatedSeconds`（加上引擎自己回報的缺口）。
///   引擎結束或被放棄時還留在等待區、沒被取走的音訊不會記成缺口。
public final class RecordingSession: @unchecked Sendable {
    // @unchecked Sendable：可變狀態分成四組，各自有保護方式——
    // - 錄音路徑（recorder、encoder）只在持有 `path` 鎖時使用。這把鎖只有 `process` 與 `finish`
    //   會拿，引擎與事件處理完全碰不到。
    // - 暫停、標記、啟動等控制操作的狀態在 `control` 鎖裡；`process` 不拿這把鎖，只讀 `pausedFlag`。
    // - 跨執行緒讀取的數值（音訊時間、暫停、引擎狀態）是 Atomic；計費與缺口的累計在 `accounting` 鎖裡，
    //   鎖裡只做加減，不做 I/O。
    // - 其餘都是建立後不再改變的常數；`JournalWriter` 與 `AsyncStream.Continuation` 本身是 thread-safe 的。
    // 所以 `process` 可能碰到的別人的鎖只有：日誌的鎖（別人持有時只是在做一次 write(2)）、
    // `accounting`（只做加減）、AsyncStream 內部的鎖（只搬動緩衝區）。它們都不會被引擎長時間持有。
    private let config: SessionConfig
    private let directory: SessionDirectory
    private let engine: any LiveCaptionEngine
    private let initialMeta: SessionMeta
    private let journal: JournalWriter
    private let recorder: SegmentedRecorder
    private let encoder: EngineAudioEncoder
    private let audioStream: AsyncStream<AudioChunk>
    private let audioInput: AsyncStream<AudioChunk>.Continuation

    private struct PathState {
        var finished = false
    }

    private struct ControlState {
        var started = false
        var finished = false
        var paused = false
        var eventTask: Task<Void, Never>?
        var finishTask: Task<SessionMeta, any Error>?
    }

    private struct Accounting {
        /// 場次自己記下的缺口（等待區丟掉的、引擎停止之後的）合計的樣本數（引擎的取樣率）。
        /// 用整數累計，長時間也不會累積浮點誤差。
        var droppedEngineFrames: Int64 = 0
        /// 引擎自己回報的缺口合計的長度（秒）。
        var engineReportedGapSeconds: Double = 0
        var billedAudioSeconds: Double = 0
    }

    private enum EngineState: UInt8, AtomicRepresentable {
        case notStarted
        case running
        case ended
    }

    private let path = Mutex(PathState())
    private let control = Mutex(ControlState())
    private let accounting = Mutex(Accounting())
    private let framesRecorded = Atomic<Int64>(0)
    private let pausedFlag = Atomic<Bool>(false)
    private let engineState = Atomic<EngineState>(.notStarted)

    /// 建立場次：建立資料夾、寫入 `session.json`（狀態為 recording）、開啟錄音與日誌。
    ///
    /// 錄音分段放在 `directory.audioDirectoryURL`，第一個樣本進來時才建立；日誌（空的 `journal.jsonl`）立刻建立。
    /// `startedAt` 以整秒記錄（`session.json` 的日期精確到秒），所以 `finish()` 回傳的內容與檔案一致。
    /// 設定不合理（取樣率、分段長度、每包長度）時，在寫入 `session.json` 之前就丟出錯誤，
    /// 不會留下一個看起來像是「錄音中被中斷」的場次。
    public init(config: SessionConfig, directory: SessionDirectory, engine: any LiveCaptionEngine) throws {
        self.config = config
        self.directory = directory
        self.engine = engine
        encoder = try EngineAudioEncoder(
            sourceRate: config.sampleRate, targetRate: config.engineSampleRate, chunkDuration: config.engineChunkDuration)
        recorder = try SegmentedRecorder(
            directory: directory.audioDirectoryURL, sampleRate: config.sampleRate, segmentDuration: config.segmentDuration)
        try directory.create()
        let meta = SessionMeta(
            id: config.id,
            title: config.title,
            startedAt: Date(timeIntervalSince1970: config.startedAt.timeIntervalSince1970.rounded(.down)),
            state: .recording,
            source: config.source,
            engine: config.engineName)
        try directory.saveMeta(meta)
        initialMeta = meta
        journal = try JournalWriter(url: directory.journalURL)
        (audioStream, audioInput) = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(Self.bufferedChunkCount(config.engineBufferDuration, config.engineChunkDuration)))
    }

    /// 等待區能放幾包：`engineBufferDuration ÷ engineChunkDuration`，四捨五入。
    private static func bufferedChunkCount(_ bufferDuration: TimeInterval, _ chunkDuration: TimeInterval) -> Int {
        let chunks = (bufferDuration / chunkDuration).rounded()
        guard chunks.isFinite else { return chunks > 0 ? Int(Int32.max) : 0 }
        return Int(min(max(chunks, 0), Double(Int32.max)))
    }

    /// 目前的音訊時間：已經錄下的長度（不含暫停）。
    public var audioTime: AudioTime {
        AudioTime(seconds: Double(framesRecorded.load(ordering: .acquiring)) / config.sampleRate)
    }

    public var isPaused: Bool { pausedFlag.load(ordering: .acquiring) }

    /// 引擎是否還在運作。引擎自己結束（例如回報失敗）之後會變成 false，錄音不受影響。
    public var isEngineRunning: Bool { engineState.load(ordering: .acquiring) == .running }

    /// 啟動引擎，開始接收字幕。
    ///
    /// 只會呼叫一次 `engine.run(audio:config:)`（帶入 `config.engine`）；重複呼叫或結束之後呼叫不做任何事。
    /// 事件由一個 task 依序處理：英文、中文寫進日誌；缺口寫進日誌並算進沒翻譯到的長度；用量更新計費秒數。
    public func start() {
        control.withLock { state in
            guard !state.started, !state.finished else { return }
            state.started = true
            engineState.store(.running, ordering: .releasing)
            let events = engine.run(audio: audioStream, config: config.engine)
            state.eventTask = Task { [self] in
                for await event in events { handle(event) }
                engineState.store(.ended, ordering: .releasing)
            }
        }
    }

    /// 送入來源樣本（單聲道、`config.sampleRate`）。同步執行，不等待引擎。
    /// 暫停中送入的樣本會被丟棄；結束之後呼叫會丟出 `RecordingSessionError.alreadyFinished`。
    ///
    /// 順序：先寫錄音檔，再推進音訊時間，再轉成引擎的格式，最後把湊滿的包放進等待區（立即返回）。
    public func process(_ samples: UnsafeBufferPointer<Float>) throws {
        try path.withLock { state in
            guard !state.finished else { throw RecordingSessionError.alreadyFinished }
            guard !pausedFlag.load(ordering: .acquiring), !samples.isEmpty else { return }
            // AVFoundation 的呼叫可能留下 autorelease 物件；Pump 的執行緒長時間不回到事件迴圈，所以每次自己清掉
            try autoreleasepool {
                try recorder.append(samples)
                framesRecorded.store(recorder.framesWritten, ordering: .releasing)
                for chunk in try encoder.encode(samples) {
                    deliver(chunk)
                }
            }
        }
    }

    /// 暫停：之後送入的樣本不錄、不送引擎，音訊時間不前進。
    /// 只有狀態真的改變時才在日誌記一筆；結束之後呼叫不做任何事。
    public func pause() {
        setPaused(true)
    }

    /// 繼續錄音。只有狀態真的改變時才在日誌記一筆；結束之後呼叫不做任何事。
    public func resume() {
        setPaused(false)
    }

    /// 在目前的音訊時間加上一個重點標記。結束之後呼叫不做任何事。
    public func mark() {
        control.withLock { state in
            guard !state.finished else { return }
            try? journal.append(.marker(at: audioTime))
        }
    }

    /// 結束錄音：關閉錄音檔、送出剩下的音訊、等引擎收尾（最多 `engineDrainTimeout`），
    /// 並把 `session.json` 更新為 finalizing。重複呼叫會回傳同一份結果。
    ///
    /// 步驟：不再接受 `process`（之後呼叫丟出 `alreadyFinished`）→ 關閉錄音檔 → 送出最後一包不滿的音訊 →
    /// 結束音訊串流 → 等引擎的事件串流結束，超過 `engineDrainTimeout` 就取消它 →
    /// 寫入最後的 `session.json`（finalizing、錄音長度、計費秒數、完整性）→ 關閉日誌。
    /// 返回時 `isEngineRunning` 一定是 false。同時呼叫好幾次也只會做一次。
    @discardableResult
    public func finish() async throws -> SessionMeta {
        let task = control.withLock { state -> Task<SessionMeta, any Error> in
            if let existing = state.finishTask { return existing }
            state.finished = true
            let eventTask = state.eventTask
            // 不跟著呼叫端被取消：結束的步驟一旦開始就要做完
            let task = Task { [self] in try await performFinish(eventTask: eventTask) }
            state.finishTask = task
            return task
        }
        return try await task.value
    }

    // MARK: 錄音路徑（持有 `path` 鎖）

    /// 把一包音訊放進引擎的等待區；放不進去的記成缺口。不等待。
    private func deliver(_ chunk: AudioChunk) {
        if engineState.load(ordering: .acquiring) == .ended {
            recordGap(of: chunk, reason: .engineStopped)
            return
        }
        switch audioInput.yield(chunk) {
        case .enqueued:
            break
        case .dropped(let oldest):
            recordGap(of: oldest, reason: .backpressure)
        case .terminated:
            recordGap(of: chunk, reason: .engineStopped)
        @unknown default:
            recordGap(of: chunk, reason: .unknown)
        }
    }

    /// 把一包沒送到引擎的音訊記成缺口。日誌寫入失敗不影響錄音（缺口的長度仍然計入完整性）。
    ///
    /// 缺口的起訖用樣本位置計算，日誌裡才不會出現 `startTime + duration` 的浮點誤差（例如 0.6000000000000001）。
    private func recordGap(of chunk: AudioChunk, reason: GapReason) {
        let rate = Double(chunk.sampleRate)
        let firstFrame = (chunk.startTime.seconds * rate).rounded()
        let gap = AudioGap(
            from: AudioTime(seconds: firstFrame / rate),
            to: AudioTime(seconds: (firstFrame + Double(chunk.frameCount)) / rate),
            reason: reason)
        try? journal.append(.gap(gap))
        accounting.withLock { $0.droppedEngineFrames += Int64(chunk.frameCount) }
    }

    // MARK: 控制與事件

    private func setPaused(_ paused: Bool) {
        control.withLock { state in
            guard !state.finished, state.paused != paused else { return }
            state.paused = paused
            pausedFlag.store(paused, ordering: .releasing)
            try? journal.append(paused ? .paused(at: audioTime) : .resumed(at: audioTime))
        }
    }

    private func handle(_ event: CaptionEvent) {
        switch event {
        case .source(let text):
            try? journal.append(.source(text))
        case .translation(let text):
            try? journal.append(.translation(text))
        case .gap(let gap):
            try? journal.append(.gap(gap))
            accounting.withLock { $0.engineReportedGapSeconds += gap.duration }
        case .usage(let audioSeconds):
            accounting.withLock { $0.billedAudioSeconds = audioSeconds }
        case .status:
            break
        }
    }

    // MARK: 結束

    private func performFinish(eventTask: Task<Void, Never>?) async throws -> SessionMeta {
        // 1. 擋住錄音路徑：等進行中的 process 做完，之後的 process 會丟出 alreadyFinished
        let closing: Result<TimeInterval, any Error> = path.withLock { state in
            state.finished = true
            return Result {
                try autoreleasepool {
                    try recorder.close()
                    if let tail = try encoder.finish() { deliver(tail) }
                    return recorder.duration
                }
            }
        }
        // 2. 音訊結束：引擎送完剩下的輸出後會自己結束事件串流
        audioInput.finish()
        // 3. 等引擎收尾，最多 engineDrainTimeout；超過就取消（引擎必須盡快停止）
        if let eventTask { await drain(eventTask, timeout: config.engineDrainTimeout) }
        engineState.store(.ended, ordering: .releasing)
        defer { journal.close() }

        let durationSeconds = try closing.get()
        let totals = accounting.withLock { $0 }
        var meta = initialMeta
        meta.state = .finalizing
        meta.durationSeconds = durationSeconds
        meta.billedAudioSeconds = totals.billedAudioSeconds
        meta.integrity = IntegrityReport(
            untranslatedSeconds: Double(totals.droppedEngineFrames) / Double(config.engineSampleRate)
                + totals.engineReportedGapSeconds)
        try directory.saveMeta(meta)
        return meta
    }

    /// 等事件處理的 task 結束；超過時限就取消它（事件串流被取消時，引擎必須盡快停止）。
    /// 返回時 task 一定已經結束，之後不會再有任何東西寫進日誌。
    private func drain(_ eventTask: Task<Void, Never>, timeout: Duration) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await eventTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            if await group.next() == false {
                eventTask.cancel()
            }
            group.cancelAll()
        }
    }
}
