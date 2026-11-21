import Foundation
import ThunderCore

/// 照劇本演出的假引擎：行為只取決於「消化了多少音訊」，不看時鐘，
/// 所以測試可以用任何速度餵音訊，結果都一樣。
///
/// 也可以演出各種故障（卡住、變慢、提早結束、不收尾），用來驗證錄音不受引擎影響。
public final class ScriptedEngine: LiveCaptionEngine, @unchecked Sendable {
    public enum Behavior: Sendable, Equatable, CustomStringConvertible {
        /// 正常：每消化 `every` 秒的音訊，送出一句英文與一句中文；音訊結束後回報用量並收尾。
        case captions(every: TimeInterval)
        /// 完全卡住：不消化音訊、不送事件，被取消才結束。
        case stalled
        /// 消化得很慢：每包先等 `perChunk` 才處理。字幕照每 2 秒一句送出。
        case slow(perChunk: Duration)
        /// 消化 `after` 秒的音訊後回報失敗並結束（例如 API Key 失效）。
        case endsEarly(after: TimeInterval)
        /// 正常消化並送字幕（每 2 秒一句），但音訊結束後不收尾，被取消才結束。
        case neverEnds

        /// 所有故障行為，給參數化測試用。
        public static let allFaults: [Behavior] = [
            .stalled,
            .slow(perChunk: .milliseconds(5)),
            .endsEarly(after: 5),
            .neverEnds,
        ]

        public var description: String {
            switch self {
            case .captions(let every): "正常（每 \(every) 秒一句）"
            case .stalled: "完全卡住"
            case .slow(let perChunk): "消化很慢（每包 \(perChunk)）"
            case .endsEarly(let after): "\(after) 秒後失敗並結束"
            case .neverEnds: "不收尾"
            }
        }
    }

    public struct ReceivedChunk: Sendable, Equatable {
        public var startTime: AudioTime
        public var frameCount: Int
        public var sampleRate: Int

        public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
        public var endTime: AudioTime { startTime + duration }
    }

    private struct State {
        var chunks: [ReceivedChunk] = []
        var chunkCount = 0
        var duration: TimeInterval = 0
        var finished = false
        var runCount = 0
        var config: EngineConfig?
    }

    private let behavior: Behavior
    private let recordsChunks: Bool
    private let state = LockedValue(State())

    /// - Parameter recordsChunks: 是否記下每一包的資料。長時間的記憶體測試請設為 false，
    ///   否則這份紀錄本身會讓記憶體持續成長。
    public init(_ behavior: Behavior, recordsChunks: Bool = true) {
        self.behavior = behavior
        self.recordsChunks = recordsChunks
    }

    // MARK: 給測試檢查的狀態

    public var receivedChunks: [ReceivedChunk] { state.value.chunks }
    public var receivedChunkCount: Int { state.value.chunkCount }
    /// 已經消化的音訊長度（秒）。
    public var receivedDuration: TimeInterval { state.value.duration }
    /// 事件串流是否已經結束。
    public var hasFinished: Bool { state.value.finished }
    public var runCount: Int { state.value.runCount }
    public var lastConfig: EngineConfig? { state.value.config }

    // MARK: 劇本內容

    public static func sourceText(_ index: Int) -> String { "en \(index)" }
    public static func translationText(_ index: Int) -> String { "中文 \(index)" }

    /// 消化 `seconds` 秒的音訊後，劇本會送出幾句字幕。
    /// 第 k 句在消化到 (k − 0.5) × every 秒時送出，刻意避開整數邊界，不受重取樣的微小誤差影響。
    public static func expectedCaptionCount(audioSeconds seconds: TimeInterval, every: TimeInterval) -> Int {
        max(0, Int((seconds / every + 0.5).rounded(.down)))
    }

    // MARK: LiveCaptionEngine

    public func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent> {
        state.withValue {
            $0.runCount += 1
            $0.config = config
            $0.finished = false
        }
        let (events, continuation) = AsyncStream<CaptionEvent>.makeStream()
        let task = Task { [self] in
            await play(audio: audio, into: continuation)
            state.withValue { $0.finished = true }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }

    private func play(audio: AsyncStream<AudioChunk>, into output: AsyncStream<CaptionEvent>.Continuation) async {
        switch behavior {
        case .stalled:
            await sleepUntilCancelled()

        case .captions(let every):
            await consume(audio, captionsEvery: every, into: output)
            if !Task.isCancelled { output.yield(.usage(audioSeconds: receivedDuration)) }

        case .slow(let perChunk):
            await consume(audio, captionsEvery: 2, delayPerChunk: perChunk, into: output)
            if !Task.isCancelled { output.yield(.usage(audioSeconds: receivedDuration)) }

        case .endsEarly(let after):
            await consume(audio, captionsEvery: 2, stopAfter: after, into: output)
            output.yield(.status(.failed(reason: "scripted failure")))

        case .neverEnds:
            await consume(audio, captionsEvery: 2, into: output)
            await sleepUntilCancelled()
        }
    }

    private func consume(
        _ audio: AsyncStream<AudioChunk>,
        captionsEvery every: TimeInterval,
        delayPerChunk: Duration? = nil,
        stopAfter: TimeInterval? = nil,
        into output: AsyncStream<CaptionEvent>.Continuation
    ) async {
        output.yield(.status(.connecting))
        output.yield(.status(.live))
        var nextCaption = 1
        for await chunk in audio {
            if let delayPerChunk {
                try? await Task.sleep(for: delayPerChunk)
                if Task.isCancelled { return }
            }
            let consumed = state.withValue { state -> TimeInterval in
                state.chunkCount += 1
                state.duration += chunk.duration
                if recordsChunks {
                    state.chunks.append(
                        ReceivedChunk(startTime: chunk.startTime, frameCount: chunk.frameCount, sampleRate: chunk.sampleRate))
                }
                return state.duration
            }
            while consumed >= (Double(nextCaption) - 0.5) * every {
                output.yield(.source(CaptionText(text: Self.sourceText(nextCaption), kind: .segmentEnd, at: chunk.endTime)))
                output.yield(
                    .translation(CaptionText(text: Self.translationText(nextCaption), kind: .segmentEnd, at: chunk.endTime)))
                nextCaption += 1
            }
            if let stopAfter, consumed >= stopAfter { return }
        }
    }

    private func sleepUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
