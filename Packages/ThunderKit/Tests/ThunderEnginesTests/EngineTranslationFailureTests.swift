import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 翻譯連續失敗（DESIGN.md 5.6.2 節）：文字模型連續回錯誤時，引擎回報 `translationFailing` 並帶出原因，英文照常；
/// 翻譯恢復時回到 `live`。偶爾失敗一兩次不改變狀態（備援與重試照常處理）。
@Suite("轉錄＋翻譯引擎：翻譯連續失敗")
struct EngineTranslationFailureTests {
    private static let keynoteSeconds = 94

    private func play(_ model: ScriptedTextModel) async throws -> [CaptionEvent] {
        let connector = ReplayConnector(fixture: try RealtimeFixture.load("keynote-single-turn"))
        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.link.backoffBase = 0.01
        configuration.link.jitter = 0
        configuration.translation.provisional = false
        let engine = TranscribeTranslateEngine(
            configuration: configuration, apiKey: "sk-test-FAKEKEY-0123456789abcdef", connector: connector, textModel: model)

        let (audio, input) = AsyncStream<AudioChunk>.makeStream()
        let events = LockedValue<[CaptionEvent]>([])
        let ended = LockedValue(false)
        let reader = Task {
            for await event in engine.run(audio: audio, config: EngineConfig()) { events.withValue { $0.append(event) } }
            ended.withValue { $0 = true }
        }
        defer { reader.cancel() }

        #expect(await waitUntil(timeout: .seconds(5)) { events.value.contains(.status(.live)) || ended.value })
        let chunk = Signal.audioChunks(Signal.silence(count: 4_800)).first!
        for second in 0..<Self.keynoteSeconds {
            for part in 0..<5 {
                var next = chunk
                next.startTime = AudioTime(seconds: Double(second) + Double(part) * 0.2)
                input.yield(next)
            }
            let target = Double(second + 1) - 0.5
            #expect(await waitUntil(timeout: .seconds(5)) { connector.receivedAudioSeconds >= target || ended.value })
        }
        input.finish()
        #expect(await waitUntil(timeout: .seconds(15)) { ended.value }, "引擎要在時限內結束")
        return events.value
    }

    private func statuses(_ events: [CaptionEvent]) -> [EngineStatus] {
        events.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }

    private func failingReasons(_ events: [CaptionEvent]) -> [String] {
        statuses(events).compactMap { if case .translationFailing(let reason) = $0 { reason } else { nil } }
    }

    @Test("文字模型一直回錯誤：狀態變成翻譯失敗並帶出原因；英文照常")
    func reportsFailure() async throws {
        let model = ScriptedTextModel { _, _ in .failure(.http(status: 404, message: "The model `gpt-x` does not exist")) }
        let events = try await play(model)
        #expect(failingReasons(events).first?.contains("HTTP 404") == true, "原因要寫出文字模型的錯誤")
        #expect(events.contains { if case .source = $0 { true } else { false } }, "英文照常")
        #expect(!events.contains { if case .translation = $0 { true } else { false } })
    }

    @Test("翻譯恢復之後，狀態回到即時")
    func recovers() async throws {
        let model = ScriptedTextModel { _, index in index < 8 ? .failure(.http(status: 503, message: "overloaded")) : .text("好了") }
        let events = try await play(model)
        let all = statuses(events)
        let failed = try #require(all.firstIndex { if case .translationFailing = $0 { true } else { false } }, "先回報翻譯失敗")
        #expect(all[(failed + 1)...].contains(.live), "恢復之後回到即時")
    }

    @Test("偶爾失敗一兩次：狀態不變")
    func toleratesFewFailures() async throws {
        let model = ScriptedTextModel { _, index in index == 3 || index == 4 ? .failure(.http(status: 500, message: "oops")) : .text("好") }
        let events = try await play(model)
        #expect(failingReasons(events).isEmpty)
    }
}
