import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 整句的暫定譯文（DESIGN.md 5.6.3 節）：重播錄下的 keynote，文字模型照劇本回答。
/// 暫定譯文以帶句子編號與這一句第一段的 `.provisional` 送出；整句定稿送出之後，那一句不再有暫定譯文。
@Suite("轉錄＋翻譯引擎：整句的暫定譯文")
struct EngineDraftTests {
    private static let keynoteSeconds = 94

    private struct Run {
        var events: [CaptionEvent]
        var model: ScriptedTextModel
    }

    private func play(sentenceProvisional: Bool) async throws -> Run {
        let connector = ReplayConnector(fixture: try RealtimeFixture.load("keynote-single-turn"))
        let model = ScriptedTextModel { request, index in
            if request.input.contains("這一句目前聽到的部分") { return .text("暫定 \(index)") }
            return .text(request.input.contains("這一句：") ? "整句 \(index)。" : "段 \(index)")
        }
        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.link.backoffBase = 0.01
        configuration.link.jitter = 0
        configuration.translation.provisional = true
        configuration.translation.sentences = true
        configuration.translation.sentenceProvisional = sentenceProvisional
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
        #expect(await waitUntil(timeout: .seconds(10)) { ended.value }, "引擎要在時限內結束")
        return Run(events: events.value, model: model)
    }

    @Test("暫定譯文帶句子的編號與這一句的第一段，屬於當時正在說的那一句；整句定稿送出之後，那一句不再有暫定譯文")
    func draftsCarrySentence() async throws {
        let run = try await play(sentenceProvisional: true)
        var openSentence: Int?
        var firstSegment: [Int: Int] = [:]
        var finished: Set<Int> = []
        var drafts = 0
        for event in run.events {
            switch event {
            case .source(let text):
                // 正在說的那一句：以進行中的英文為準（晚到的標點與尾巴屬於上一段，帶的是那一段的句子）
                if text.kind == .delta { openSentence = text.sentence }
                if let sentence = text.sentence, let segment = text.segment, firstSegment[sentence] == nil {
                    firstSegment[sentence] = segment
                }
            case .provisional(let text):
                drafts += 1
                let sentence = try #require(text.sentence, "暫定譯文要帶句子的編號")
                #expect(text.sentenceStart == firstSegment[sentence], "第 \(sentence) 句的暫定譯文要帶這一句的第一段")
                #expect(sentence == openSentence, "暫定譯文屬於正在說的那一句")
                #expect(!finished.contains(sentence), "第 \(sentence) 句的整句定稿已經送出，不再有暫定譯文")
                #expect(text.text.hasPrefix("暫定"))
            case .translation(let text):
                if let sentence = text.sentence, text.sentenceStart != nil { finished.insert(sentence) }
            default:
                break
            }
        }
        #expect(drafts > 0, "有暫定譯文")
        #expect(run.model.requests.contains { $0.input.contains("這一句目前聽到的部分") })
    }

    @Test("沒有開整句的暫定譯文：照舊逐段送暫定譯文（不帶句子的編號）")
    func segmentDrafts() async throws {
        let run = try await play(sentenceProvisional: false)
        let provisionals = run.events.compactMap { if case .provisional(let text) = $0 { text } else { nil } }
        #expect(!provisionals.isEmpty)
        #expect(provisionals.allSatisfy { $0.sentence == nil && $0.sentenceStart == nil })
        #expect(!run.model.requests.contains { $0.input.contains("這一句目前聽到的部分") })
    }
}
