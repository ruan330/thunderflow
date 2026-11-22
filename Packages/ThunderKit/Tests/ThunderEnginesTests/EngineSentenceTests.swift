import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 整句模式的引擎（DESIGN.md 5.6.2 節）：英文帶句子的編號，整句定稿以帶 `sentenceStart` 的中文定稿送出。
/// 重播錄下的 keynote（合成語音，一句通常就是一段），文字模型照劇本回答：整句的請求回「整句 n」，段的請求回「段 n」。
@Suite("轉錄＋翻譯引擎：整句模式")
struct EngineSentenceTests {
    private static let keynoteSeconds = 94

    private struct Run {
        var events: [CaptionEvent]
        var model: ScriptedTextModel
    }

    private func play(sentences: Bool) async throws -> Run {
        let connector = ReplayConnector(fixture: try RealtimeFixture.load("keynote-single-turn"))
        let model = ScriptedTextModel { request, index in
            .text(request.input.contains("這一句：") ? "整句 \(index)。" : "段 \(index)")
        }
        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.link.backoffBase = 0.01
        configuration.link.jitter = 0
        configuration.translation.provisional = false
        configuration.translation.sentences = sentences
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

    @Test("英文帶句子的編號（從 0 開始、一次最多加 1）；每一句都有整句定稿，依順序，涵蓋的段和英文的句子編號一致；一句的最後一段沒有自己的定稿")
    func sentenceFinals() async throws {
        let run = try await play(sentences: true)
        let sources = run.events.compactMap { if case .source(let text) = $0 { text } else { nil } }
        #expect(!sources.isEmpty)
        #expect(sources.allSatisfy { $0.sentence != nil }, "每一筆英文都帶句子的編號")

        // 每一段以最後一次確定的英文為準
        var sentenceOf: [Int: Int] = [:]
        for text in sources where text.kind == .segmentEnd {
            if let segment = text.segment, let sentence = text.sentence { sentenceOf[segment] = sentence }
        }
        let segments = sentenceOf.keys.sorted()
        let labels = segments.compactMap { sentenceOf[$0] }
        #expect(labels.first == 0)
        #expect(zip(labels, labels.dropFirst()).allSatisfy { $1 == $0 || $1 == $0 + 1 }, "句子的編號依序，一次最多加 1")

        let translations = run.events.compactMap { if case .translation(let text) = $0 { text } else { nil } }
        let finals = translations.filter { $0.sentenceStart != nil }
        #expect(finals.compactMap(\.sentence) == Array(Set(labels)).sorted(), "每一句都有整句定稿，依句子的順序")
        for final in finals {
            guard let first = final.sentenceStart, let last = final.segment, let sentence = final.sentence else { continue }
            let covered = segments.filter { sentenceOf[$0] == sentence }
            #expect(Array(first...last) == covered, "第 \(sentence) 句的整句定稿涵蓋的段，要和英文的句子編號一致")
            #expect(final.text.hasPrefix("整句"), "整句定稿用的是整句的請求的結果")
        }
        let lastSegments = Set(finals.compactMap(\.segment))
        let ownFinals = translations.filter { $0.sentenceStart == nil }.compactMap(\.segment)
        #expect(lastSegments.isDisjoint(with: ownFinals), "一句的最後一段不送自己的定稿")
        #expect(run.model.requests.contains { $0.input.contains("這一句：") && $0.instructions.contains("口語") })
    }

    @Test("不是整句模式：英文與定稿都不帶句子的編號，也沒有整句的請求")
    func segmentMode() async throws {
        let run = try await play(sentences: false)
        let texts = run.events.compactMap { event -> CaptionText? in
            switch event {
            case .source(let text), .translation(let text): text
            default: nil
            }
        }
        #expect(!texts.isEmpty)
        #expect(texts.allSatisfy { $0.sentence == nil && $0.sentenceStart == nil })
        #expect(!run.model.requests.contains { $0.input.contains("這一句：") })
    }
}
