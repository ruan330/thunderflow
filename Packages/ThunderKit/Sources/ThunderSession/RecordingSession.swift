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
/// - 引擎拿到的是包在等待區外面的串流，場次因此知道引擎實際取走了多少。
/// - 引擎結束（事件串流自己結束，例如回報失敗）或結束錄音時被放棄之後，等待區也跟著放棄：
///   裡面還沒被取走的音訊（一定是連續的一段）記成一筆原因為 `engineStopped` 的缺口，
///   之後送進來的音訊也一包一包記成 `engineStopped`。這兩者在時間上是接起來的。
/// - 因此每一段音訊不是被引擎取走，就是記成缺口：引擎取走的長度加上缺口的長度，等於整場錄音。
///   日誌裡場次記下的缺口加上引擎自己回報的缺口，就是 `integrity.untranslatedSeconds`。
///   唯一的例外是引擎被取消的那一瞬間手上正拿著、還沒處理完的那一包：它算成已經取走。
public final class RecordingSession: @unchecked Sendable {
    // @unchecked Sendable：可變狀態分成四組，各自有保護方式——
    // - 錄音路徑（recorder、encoder，以及 `PathState` 裡等待區的帳）只在持有 `path` 鎖時使用。
    //   這把鎖只有 `process` 與 `finish` 會拿，引擎與事件處理完全碰不到。
    // - 暫停、標記、啟動等控制操作的狀態在 `control` 鎖裡；`process` 不拿這把鎖，只讀 `pausedFlag`。
    // - 跨執行緒讀取的數值（音訊時間、暫停、引擎狀態）是 Atomic；引擎回報的缺口與計費在 `accounting` 鎖裡，
    //   鎖裡只做加減，不做 I/O。引擎取走了多少記在 `WaitingArea` 的 Atomic 裡。
    // - 其餘都是建立後不再改變的常數；`JournalWriter` 與 `WaitingArea` 本身是 thread-safe 的。
    // 所以 `process` 可能碰到的別人的鎖只有：日誌的鎖（別人持有時只是在做一次 write(2)）
    // 與 AsyncStream 內部的鎖（只搬動緩衝區）。它們都不會被引擎長時間持有。
    private let config: SessionConfig
    private let directory: SessionDirectory
    private let engine: any LiveCaptionEngine
    private let initialMeta: SessionMeta
    private let journal: JournalWriter
    private let recorder: SegmentedRecorder
    private let encoder: EngineAudioEncoder
    private let waitingArea: WaitingArea

    /// 錄音路徑的狀態。樣本數都是引擎的取樣率；送給引擎的包從 0 開始一包接一包，所以樣本數也就是時間軸上的位置。
    private struct PathState {
        var finished = false
        /// 放進等待區的樣本數，也就是最後放進去的那一包的結束位置。
        var queuedFrames: Int64 = 0
        /// 被等待區擠掉（記成 backpressure）的樣本數。
        var squeezedOutFrames: Int64 = 0
        /// 等待區已經放棄：之後的音訊直接記成 engineStopped。
        var abandoned = false
        /// 場次自己記下的缺口合計的樣本數。用整數累計，長時間也不會累積浮點誤差。
        var gapFrames: Int64 = 0
    }

    private struct ControlState {
        var started = false
        var finished = false
        var paused = false
        var eventTask: Task<Void, Never>?
        var finishTask: Task<SessionMeta, any Error>?
    }

    /// 事件處理寫入、結束時讀取的累計。
    private struct Accounting {
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
            engine: config.engineName,
            event: config.event,
            speaker: config.speaker,
            keywords: config.keywords)
        try directory.saveMeta(meta)
        initialMeta = meta
        journal = try JournalWriter(url: directory.journalURL)
        waitingArea = WaitingArea(capacity: Self.bufferedChunkCount(config.engineBufferDuration, config.engineChunkDuration))
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

    /// 錄音檔寫不進去（例如磁碟滿了）而沒有錄到的長度（秒）。可以從任何執行緒讀取。
    ///
    /// 尚未實作：介面先行，見 `RecordingWriteFailureTests`。
    public var unrecordedSeconds: Double { 0 }

    /// 引擎是否還在運作。引擎自己結束（例如回報失敗）之後會變成 false，錄音不受影響。
    public var isEngineRunning: Bool { engineState.load(ordering: .acquiring) == .running }

    /// 啟動引擎，開始接收字幕。
    ///
    /// 只會呼叫一次 `engine.run(audio:config:)`（帶入 `config.engine`）；重複呼叫或結束之後呼叫不做任何事。
    /// 引擎拿到的音訊串流就是等待區（包了一層，用來記下引擎取走了多少）。
    /// 事件由一個 task 依序處理：英文、中文寫進日誌；缺口寫進日誌並算進沒翻譯到的長度；用量更新計費秒數。
    public func start() {
        control.withLock { state in
            guard !state.started, !state.finished else { return }
            state.started = true
            engineState.store(.running, ordering: .releasing)
            let events = engine.run(audio: waitingArea.engineStream(), config: config.engine)
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
                    deliver(chunk, &state)
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
    /// 放棄等待區，引擎沒取走的音訊記成 engineStopped 的缺口 →
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
    ///
    /// 第一次發現引擎已經結束時，先放棄等待區（裡面引擎沒取走的音訊記成缺口），再把這一包記成 engineStopped。
    private func deliver(_ chunk: AudioChunk, _ state: inout PathState) {
        if !state.abandoned, engineState.load(ordering: .acquiring) == .ended {
            abandonWaitingArea(&state)
        }
        if state.abandoned {
            recordGap(of: chunk, reason: .engineStopped, &state)
            return
        }
        switch waitingArea.yield(chunk) {
        case .enqueued:
            state.queuedFrames += Int64(chunk.frameCount)
        case .dropped(let oldest):
            state.queuedFrames += Int64(chunk.frameCount)
            state.squeezedOutFrames += Int64(oldest.frameCount)
            recordGap(of: oldest, reason: .backpressure, &state)
        case .terminated:
            // 等待區已經關閉（引擎讀音訊的 task 被取消了）：引擎再也收不到音訊
            abandonWaitingArea(&state)
            recordGap(of: chunk, reason: .engineStopped, &state)
        @unknown default:
            abandonWaitingArea(&state)
            recordGap(of: chunk, reason: .engineStopped, &state)
        }
    }

    /// 放棄等待區：引擎已經結束或被放棄。只做一次。
    ///
    /// 等待區丟掉的、引擎取走的都是當時最舊的那一包，所以還留在裡面的是從
    /// 「被擠掉的＋被取走的」那個位置到最後放進去的那一包為止，連續的一段；把它記成一筆 engineStopped 的缺口。
    /// 放棄之後引擎再也拿不到這些音訊，所以每一包只會被算一次。
    private func abandonWaitingArea(_ state: inout PathState) {
        guard !state.abandoned else { return }
        state.abandoned = true
        guard let consumedFrames = waitingArea.abandon() else { return }
        let firstFrame = state.squeezedOutFrames + consumedFrames
        recordGap(fromFrame: firstFrame, frameCount: state.queuedFrames - firstFrame, reason: .engineStopped, &state)
    }

    /// 把一包沒送到引擎的音訊記成缺口。
    private func recordGap(of chunk: AudioChunk, reason: GapReason, _ state: inout PathState) {
        let firstFrame = Int64((chunk.startTime.seconds * Double(chunk.sampleRate)).rounded())
        recordGap(fromFrame: firstFrame, frameCount: Int64(chunk.frameCount), reason: reason, &state)
    }

    /// 把一段沒送到引擎的音訊（引擎取樣率的樣本位置）記成缺口。日誌寫入失敗不影響錄音（長度仍然計入完整性）。
    ///
    /// 缺口的起訖用樣本位置計算，日誌裡才不會出現 `startTime + duration` 的浮點誤差（例如 0.6000000000000001）。
    private func recordGap(fromFrame firstFrame: Int64, frameCount: Int64, reason: GapReason, _ state: inout PathState) {
        guard frameCount > 0 else { return }
        let rate = Double(config.engineSampleRate)
        let gap = AudioGap(
            from: AudioTime(seconds: Double(firstFrame) / rate),
            to: AudioTime(seconds: Double(firstFrame + frameCount) / rate),
            reason: reason)
        try? journal.append(.gap(gap))
        state.gapFrames += frameCount
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
        case .provisional:
            // 暫定譯文只給畫面用，會被定稿取代，不寫進日誌
            break
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
                    if let tail = try encoder.finish() { deliver(tail, &state) }
                    return recorder.duration
                }
            }
        }
        // 2. 音訊結束：引擎取完等待區裡剩下的音訊、送完剩下的輸出後，會自己結束事件串流
        waitingArea.finish()
        // 3. 等引擎收尾，最多 engineDrainTimeout；超過就取消（引擎必須盡快停止）
        if let eventTask { await drain(eventTask, timeout: config.engineDrainTimeout) }
        engineState.store(.ended, ordering: .releasing)
        defer { journal.close() }
        // 4. 引擎到這時還沒取走的音訊（例如引擎卡住、被放棄），記成 engineStopped 的缺口
        let gapFrames = path.withLock { state -> Int64 in
            abandonWaitingArea(&state)
            return state.gapFrames
        }

        let durationSeconds = try closing.get()
        let totals = accounting.withLock { $0 }
        var meta = initialMeta
        meta.state = .finalizing
        meta.durationSeconds = durationSeconds
        meta.billedAudioSeconds = totals.billedAudioSeconds
        meta.integrity = IntegrityReport(
            untranslatedSeconds: Double(gapFrames) / Double(config.engineSampleRate) + totals.engineReportedGapSeconds)
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
