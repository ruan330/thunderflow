import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 測試工具自己的測試。這些在「紅燈」階段就必須是綠的：工具不可靠，後面的測試就沒有意義。
@Suite("測試工具")
struct TestKitTests {
    /// `seconds` 秒、每包 200 ms 的 24 kHz 靜音。
    private func chunks(seconds: Double) -> [AudioChunk] {
        let count = Int((seconds / 0.2).rounded())
        return (0..<count).map { index in
            AudioChunk(
                pcm16: Data(count: 4_800 * 2), sampleRate: 24_000, startTime: AudioTime(seconds: Double(index) * 0.2))
        }
    }

    private func finishedStream(of chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func collect(_ events: AsyncStream<CaptionEvent>) async -> [CaptionEvent] {
        var all: [CaptionEvent] = []
        for await event in events { all.append(event) }
        return all
    }

    @Test("腳本引擎（正常）：依消化的音訊量送出字幕，最後回報用量並收尾", .timeLimit(.minutes(1)))
    func scriptedCaptions() async {
        let engine = ScriptedEngine(.captions(every: 2))
        let events = await collect(engine.run(audio: finishedStream(of: chunks(seconds: 10)), config: EngineConfig()))

        let sources = events.compactMap { event -> CaptionText? in
            if case .source(let text) = event { text } else { nil }
        }
        let translations = events.compactMap { event -> CaptionText? in
            if case .translation(let text) = event { text } else { nil }
        }
        #expect(sources.map(\.text) == (1...5).map(ScriptedEngine.sourceText))
        #expect(translations.map(\.text) == (1...5).map(ScriptedEngine.translationText))
        #expect(sources.map(\.at) == sources.map(\.at).sorted())
        #expect(ScriptedEngine.expectedCaptionCount(audioSeconds: 10, every: 2) == 5)

        guard case .usage(let billed)? = events.last else {
            Issue.record("最後一個事件應該是用量回報")
            return
        }
        #expect(abs(billed - 10) < 1e-6)
        #expect(engine.hasFinished)
        #expect(engine.receivedChunkCount == 50)
        #expect(abs(engine.receivedDuration - 10) < 1e-6)
        #expect(engine.lastConfig == EngineConfig())
    }

    @Test("腳本引擎（卡住）：不消化音訊，被取消後才結束", .timeLimit(.minutes(1)))
    func scriptedStall() async {
        let engine = ScriptedEngine(.stalled)
        let events = engine.run(audio: finishedStream(of: chunks(seconds: 2)), config: EngineConfig())
        let consumer = Task { await collect(events) }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(!engine.hasFinished)
        #expect(engine.receivedChunkCount == 0)

        consumer.cancel()
        _ = await consumer.value
        #expect(waitUntil { engine.hasFinished })
    }

    @Test("腳本引擎（提早結束）：消化指定長度後回報失敗並結束", .timeLimit(.minutes(1)))
    func scriptedEarlyEnd() async {
        let engine = ScriptedEngine(.endsEarly(after: 1))
        let events = await collect(engine.run(audio: finishedStream(of: chunks(seconds: 10)), config: EngineConfig()))

        #expect(events.last == .status(.failed(reason: "scripted failure")))
        #expect(engine.hasFinished)
        #expect(engine.receivedDuration >= 1 && engine.receivedDuration < 1.5)
    }

    @Test("腳本引擎（不收尾）：音訊結束後事件串流不會自己結束", .timeLimit(.minutes(1)))
    func scriptedNeverEnds() async {
        let engine = ScriptedEngine(.neverEnds)
        let events = engine.run(audio: finishedStream(of: chunks(seconds: 2)), config: EngineConfig())
        let consumer = Task { await collect(events) }

        #expect(waitUntil { engine.receivedChunkCount == 10 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!engine.hasFinished)

        consumer.cancel()
        _ = await consumer.value
    }

    @Test("withDeadline：做得完就回傳結果，卡住就丟出逾時錯誤", .timeLimit(.minutes(1)))
    func deadline() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)

        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    @Test("completesWithin：分辨得出做得完與卡住")
    func synchronousDeadline() {
        #expect(completesWithin(.seconds(5)) {})
        #expect(!completesWithin(.milliseconds(50)) { sleep(2) })
    }

    @Test("序號訊號：找得出第一個不符的位置")
    func sequenceSignal() {
        var samples = Signal.sequence(from: 10, count: 100)
        #expect(Signal.firstMismatch(in: samples, sequenceFrom: 10) == nil)
        samples[37] += 1
        #expect(Signal.firstMismatch(in: samples, sequenceFrom: 10) == 37)

        // 跨過重新計數的邊界也正確
        let wrapped = Signal.sequence(from: Signal.sequenceModulus - 3, count: 6)
        #expect(wrapped == [1_000_000, 1_000_001, 1_000_002, 0, 1, 2])
    }

    @Test("正弦波：樣本數精確，過零次數約為頻率的兩倍")
    func sineSignal() {
        let sine = Signal.sine(frequency: 100, sampleRate: 8_000, duration: 1, amplitude: 0.5)
        #expect(sine.count == 8_000)
        #expect(sine.map(abs).max()! <= 0.5)
        let pcm = sine.map { Int16(($0 * 32_767).rounded()) }
        #expect(abs(Signal.zeroCrossings(pcm) - 200) <= 2)
    }

    @Test("效能預算檔讀得到，M1 用到的預算都有數值")
    func budgetsLoad() throws {
        let budgets = try PerfBudgets.load()
        for key in [
            "ring.throughput.realtimeFactor.min",
            "recorder.throughput.realtimeFactor.min",
            "encoder.throughput.realtimeFactor.min",
            "session.pipeline.realtimeFactor.min",
            "journal.append.microseconds.max",
            "session.memoryGrowth.megabytes.max",
            "session.soak8h.memoryGrowth.megabytes.max",
        ] {
            #expect(try budgets.minimum(key) > 0, "缺少預算：\(key)")
        }
        #expect(throws: PerfBudgets.MissingBudget.self) { try budgets.maximum("no.such.budget") }
    }

    @Test("效能預算的放寬係數：上限放大、下限縮小")
    func budgetFactor() throws {
        let budgets = PerfBudgets(values: ["time.max": 100, "speed.min": 300], factor: 3)
        #expect(try budgets.maximum("time.max") == 300)
        #expect(try budgets.minimum("speed.min") == 100)
    }
}
