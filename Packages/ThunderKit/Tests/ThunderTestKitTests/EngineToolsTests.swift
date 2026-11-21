import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// M2 加入的測試工具。和其他測試工具一樣，在「紅燈」階段就必須是綠的。
@Suite("測試工具：語音場景、腳本引擎的分段、錄下來的事件")
struct EngineToolsTests {
    @Test("speechLike：開頭與結尾是有聲的部分，音節之間變小聲")
    func speechLikeEnvelope() {
        let samples = Signal.speechLike(sampleRate: 24_000, duration: 1.8, amplitude: 0.2)
        let frame = 480  // 20 ms
        func level(atFrame index: Int) -> Double { Signal.rms(Array(samples[(index * frame)..<((index + 1) * frame)])) }
        let voiced = 0.2 * 0.7071 * 32767

        #expect(samples.count == 43_200)
        #expect(abs(level(atFrame: 0) - voiced) < voiced * 0.05)
        // 第 1 個音節的後 60 ms（第 6–8 格）是有聲部分的四分之一
        #expect(abs(level(atFrame: 7) - voiced * 0.25) < voiced * 0.05)
        // 最後 70 ms 不變小聲：最後一格是有聲的
        #expect(abs(level(atFrame: 89) - voiced) < voiced * 0.05)
    }

    @Test("noise：音量對得上；同一個 seed 每次都一樣，不同的 seed 不一樣")
    func noiseIsReproducible() {
        let first = Signal.noise(rms: 500, count: 24_000, seed: 7)
        #expect(abs(Signal.rms(first) - 500) < 15)
        #expect(first == Signal.noise(rms: 500, count: 24_000, seed: 7))
        #expect(first != Signal.noise(rms: 500, count: 24_000, seed: 8))
        #expect(Signal.rms(Signal.silence(count: 100)) == 0)
    }

    @Test("SpeechScene：樣本數、每段語音的起訖都對得上；兩段可以接起來")
    func speechScene() {
        let scene = SpeechScene([.silence(0.5), .speech(2.0), .silence(0.4), .speech(1.0), .speech(0.5)], noiseRMS: 300)
        #expect(scene.samples.count == 24_000 * 44 / 10)
        #expect(abs(scene.duration - 4.4) < 1e-9)
        #expect(scene.speechIntervals.count == 2)
        #expect(abs(scene.speechIntervals[0].lowerBound - 0.5) < 1e-9 && abs(scene.speechIntervals[0].upperBound - 2.5) < 1e-9)
        // 相鄰的兩段語音算成一段
        #expect(abs(scene.speechIntervals[1].lowerBound - 2.9) < 1e-9 && abs(scene.speechIntervals[1].upperBound - 4.4) < 1e-9)
        // 停頓的地方只有底噪
        #expect(abs(Signal.rms(Array(scene.samples[0..<12_000])) - 300) < 15)

        let joined = scene + SpeechScene([.speech(1.0)])
        #expect(abs(joined.duration - 5.4) < 1e-9)
        #expect(joined.speechIntervals.count == 3)
        #expect(abs((joined.speechIntervals.last?.lowerBound ?? 0) - 4.4) < 1e-9)
    }

    @Test("audioChunks：一包接一包、時間連續、樣本一個不少，最後不滿一包也送出")
    func audioChunks() {
        let samples = Signal.sine(frequency: 440, sampleRate: 24_000, duration: 0.5)
        let chunks = Signal.audioChunks(samples, sampleRate: 24_000, chunkDuration: 0.2, startTime: AudioTime(seconds: 3))

        #expect(chunks.map(\.frameCount) == [4_800, 4_800, 2_400])
        #expect(chunks.map(\.startTime.seconds) == [3.0, 3.2, 3.4])
        #expect(chunks.allSatisfy { $0.sampleRate == 24_000 })
        #expect(Signal.int16Samples(of: chunks).count == samples.count)
        #expect(Signal.int16Samples(Signal.pcm16([0.5, -0.5, 2.0, -2.0])) == [16_384, -16_384, 32_767, -32_768])
    }

    @Test("SeededGenerator：同一個 seed 的序列相同")
    func seededGenerator() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        var other = SeededGenerator(seed: 43)
        let a = (0..<8).map { _ in first.next() }
        #expect(a == (0..<8).map { _ in second.next() })
        #expect(a != (0..<8).map { _ in other.next() })
    }

    @Test("腳本引擎（分段）：每一段依序送出暫定譯文、英文、中文定稿，三者段號相同", .timeLimit(.minutes(1)))
    func scriptedSegments() async {
        let engine = ScriptedEngine(.segments(every: 2))
        let chunks = Signal.audioChunks(Signal.silence(count: 24_000 * 4), sampleRate: 24_000)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()

        var events: [CaptionEvent] = []
        for await event in engine.run(audio: stream, config: EngineConfig()) { events.append(event) }
        let captions = events.filter {
            switch $0 {
            case .source, .translation, .provisional: true
            default: false
            }
        }

        // 4 秒的音訊、每 2 秒一段：消化到第 1 秒與第 3 秒時各完成一段
        #expect(captions.count == 6)
        guard captions.count == 6 else { return }
        for index in 0..<2 {
            guard case .provisional(let provisional) = captions[index * 3], case .source(let source) = captions[index * 3 + 1],
                case .translation(let translation) = captions[index * 3 + 2]
            else {
                Issue.record("第 \(index) 段的順序不對：\(captions)")
                continue
            }
            #expect(provisional.text == ScriptedEngine.provisionalText(index + 1) && provisional.segment == index)
            #expect(source.text == ScriptedEngine.sourceText(index + 1) && source.segment == index && source.kind == .segmentEnd)
            #expect(
                translation.text == ScriptedEngine.translationText(index + 1) && translation.segment == index
                    && translation.kind == .segmentEnd)
        }
    }

    @Test("TranscriptFixture：讀得到錄下來的增量文字、停頓與句子")
    func transcriptFixture() throws {
        let fixture = try TranscriptFixture.load(events: "keynote-single-turn", audio: "keynote")

        #expect(fixture.deltas.count > 250)
        #expect(fixture.text.hasPrefix(" Good morning everyone"))
        #expect(zip(fixture.deltas, fixture.deltas.dropFirst()).allSatisfy { $0.time <= $1.time })
        #expect(fixture.pauses.count == 19)
        #expect(fixture.pauses.allSatisfy { abs(($0.detectedAt - $0.speechEnd) - 0.3) < 1e-9 })
        #expect(fixture.sentences.count == 19)
        #expect(fixture.sentences.first?.text == "Good morning everyone, and welcome to the conference.")

        let withoutAudio = try TranscriptFixture.load(events: "mixed-zh-en")
        #expect(!withoutAudio.deltas.isEmpty && withoutAudio.pauses.isEmpty && withoutAudio.sentences.isEmpty)
    }
}
