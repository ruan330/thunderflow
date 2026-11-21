import Foundation
import Testing
import ThunderEngines
import ThunderTestKit

/// 重播的結果：每一段的文字（已補上晚到的標點）、確定的時間與原因。
struct ReplayedSegment: Equatable {
    var text: String
    var finishedAt: TimeInterval
    var reason: Segmenter.Reason
}

/// 依時間順序把增量文字與停頓送進切段。兩個事件之間如果有計時到期，就在到期的那一刻呼叫 `advance`，
/// 和引擎實際執行時一樣；最後 `flush`。
func replay(
    _ fixture: TranscriptFixture,
    usingPauses: Bool,
    configuration: Segmenter.Configuration = Segmenter.Configuration()
) -> [ReplayedSegment] {
    enum Input {
        case text(String)
        case pause(speechEnd: TimeInterval)
    }
    var inputs: [(time: TimeInterval, order: Int, input: Input)] = fixture.deltas.enumerated().map {
        ($1.time, $0, .text($1.text))
    }
    if usingPauses {
        inputs += fixture.pauses.enumerated().map { ($1.detectedAt, $0, .pause(speechEnd: $1.speechEnd)) }
    }
    inputs.sort { ($0.time, $0.order) < ($1.time, $1.order) }

    var segmenter = Segmenter(configuration: configuration)
    var segments: [ReplayedSegment] = []
    func apply(_ outputs: [Segmenter.Output], at time: TimeInterval) {
        for output in outputs {
            switch output {
            case .delta:
                break
            case .finished(let segment, let text, let reason):
                if segment != segments.count { Issue.record("段號應該連續：第 \(segments.count) 段卻編成 \(segment)") }
                segments.append(ReplayedSegment(text: text, finishedAt: time, reason: reason))
            case .amended(let segment, let text), .extended(let segment, let text):
                guard segments.indices.contains(segment) else {
                    Issue.record("補的是不存在的第 \(segment) 段")
                    continue
                }
                segments[segment].text = text
                if case .extended = output { segments[segment].finishedAt = time }
            }
        }
    }
    for (time, _, input) in inputs {
        while let deadline = segmenter.nextDeadline, deadline <= time {
            apply(segmenter.advance(to: deadline), at: deadline)
        }
        switch input {
        case .text(let text): apply(segmenter.receive(text, at: time), at: time)
        case .pause(let speechEnd): apply(segmenter.pauseDetected(speechEnd: speechEnd, at: time), at: time)
        }
    }
    let end = (inputs.last?.time ?? 0) + 10
    while let deadline = segmenter.nextDeadline, deadline <= end {
        apply(segmenter.advance(to: deadline), at: deadline)
    }
    apply(segmenter.flush(at: end), at: end)
    return segments
}

private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// 去掉所有空白。中文的句子之間沒有空白，比對「文字一個不少」時不看空白。
private func withoutWhitespace(_ text: String) -> String {
    String(text.filter { !$0.isWhitespace })
}

/// 每一句說完之後，多久有一段在那裡結束。找不到（那一句沒有在句尾被切開）回傳 nil。
private func delaysAfterEachSentence(_ segments: [ReplayedSegment], _ fixture: TranscriptFixture) -> [TimeInterval?] {
    fixture.sentences.enumerated().map { index, sentence in
        let nextStart = index + 1 < fixture.sentences.count ? fixture.sentences[index + 1].end : .infinity
        return segments.first { $0.finishedAt >= sentence.end && $0.finishedAt < nextStart }.map { $0.finishedAt - sentence.end }
    }
}

private func median(_ values: [TimeInterval]) -> TimeInterval {
    let ordered = values.sorted()
    return ordered.isEmpty ? .infinity : ordered[ordered.count / 2]
}

/// 合成語音 keynote（19 句，句與句之間停 0.35 秒以上）以即時速度送進純轉錄連線、整段不 commit 時錄下的事件，
/// 加上同一段音檔的停頓時間。
@Suite("Segmenter：重播錄下的事件")
struct SegmenterReplayTests {
    @Test("有停頓資料：文字一個不少，每一段都是完整的句子，句子說完不到 0.8 秒（中位數）就確定")
    func keynoteWithPauses() throws {
        let fixture = try TranscriptFixture.load(events: "keynote-single-turn", audio: "keynote")
        let segments = replay(fixture, usingPauses: true)

        #expect(normalized(segments.map(\.text).joined(separator: " ")) == normalized(fixture.text))
        #expect(segments.allSatisfy { $0.text.last.map { ".?!".contains($0) } ?? false }, "實際：\(segments.map(\.text))")
        #expect(segments.allSatisfy { $0.text.split(separator: " ").count >= 2 })
        // 每一句的結尾都有一段在那裡結束
        let delays = delaysAfterEachSentence(segments, fixture)
        #expect(!delays.contains(nil), "有句子沒有在句尾被切開：\(delays)")
        let known = delays.compactMap { $0 }
        #expect(median(known) <= 0.8, "中位數 \(median(known)) 秒")
        #expect((known.max() ?? .infinity) <= 1.6, "最慢 \(known.max() ?? -1) 秒")
        // 大部分是靠停頓確定的，不是等到下一句開口才出現的句號
        #expect(segments.filter { $0.reason == .pause }.count >= fixture.sentences.count / 2)
    }

    @Test("沒有停頓資料（完全偵測不到停頓）：只靠句號也切得完，文字一個不少，只是比較晚")
    func keynoteWithoutPauses() throws {
        let fixture = try TranscriptFixture.load(events: "keynote-single-turn", audio: "keynote")
        let segments = replay(fixture, usingPauses: false)

        #expect(normalized(segments.map(\.text).joined(separator: " ")) == normalized(fixture.text))
        #expect(segments.allSatisfy { $0.text.last.map { ".?!".contains($0) } ?? false })
        #expect(segments.allSatisfy { $0.reason == .sentenceEnd || $0.reason == .idle || $0.reason == .flush })
        let delays = delaysAfterEachSentence(segments, fixture)
        #expect(!delays.contains(nil), "有句子沒有在句尾被切開：\(delays)")
        #expect(median(delays.compactMap { $0 }) <= 1.5)
    }

    @Test("有停頓資料時，每一句確定得比只靠句號早")
    func pausesMakeItFaster() throws {
        let fixture = try TranscriptFixture.load(events: "keynote-single-turn", audio: "keynote")
        let withPauses = delaysAfterEachSentence(replay(fixture, usingPauses: true), fixture).compactMap { $0 }
        let withoutPauses = delaysAfterEachSentence(replay(fixture, usingPauses: false), fixture).compactMap { $0 }

        #expect(median(withPauses) < median(withoutPauses))
    }

    @Test("中英夾雜的來源：中文的句號也切得開，文字一個不少")
    func mixedChineseAndEnglish() throws {
        let fixture = try TranscriptFixture.load(events: "mixed-zh-en")
        let segments = replay(fixture, usingPauses: false)

        #expect(withoutWhitespace(segments.map(\.text).joined()) == withoutWhitespace(fixture.text))
        #expect(segments.count >= 6)
        #expect(segments.contains { $0.text.contains("Amazon Bedrock") })
    }
}

@Suite("Segmenter：不變條件 8")
struct SegmenterInvariantTests {
    @Test("隨機的文字、標點、停頓與時間：每個字恰好屬於一段，段號連續，補標點只補在最近確定的那一段", arguments: 1...24)
    func everyWordBelongsToExactlyOneSegment(seed: Int) {
        var random = SeededGenerator(seed: UInt64(seed))
        var segmenter = Segmenter()
        var now = 0.0
        var original: [String] = []
        var outputs: [Segmenter.Output] = []
        let vocabulary = ["alpha", "beta", "1.5", "gamma", "delta", "S3", "omega", "AgentCore"]
        let marks = ["", "", "", "", ",", ".", "?", "!"]

        for _ in 0..<400 {
            now += [0.05, 0.1, 0.2, 0.3, 0.5, 0.9, 1.4, 2.6].randomElement(using: &random)!
            let word = vocabulary.randomElement(using: &random)!
            let mark = marks.randomElement(using: &random)!
            original.append(word + mark)
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                // 字和標點在同一個增量裡
                outputs += segmenter.receive(" " + word + mark, at: now)
            case 1:
                // 標點緊接著來
                outputs += segmenter.receive(" " + word, at: now)
                if !mark.isEmpty {
                    now += 0.01
                    outputs += segmenter.receive(mark, at: now)
                }
            default:
                // 標點晚到（真實的串流常常這樣）
                outputs += segmenter.receive(" " + word, at: now)
                if !mark.isEmpty {
                    now += [0.3, 0.8, 1.2].randomElement(using: &random)!
                    outputs += segmenter.receive(mark, at: now)
                }
            }
            if Int.random(in: 0..<5, using: &random) == 0 {
                now += 0.3
                outputs += segmenter.pauseDetected(speechEnd: now - 0.3, at: now)
            }
            if Int.random(in: 0..<7, using: &random) == 0 {
                now += 0.25
                outputs += segmenter.advance(to: now)
            }
        }
        outputs += segmenter.flush(at: now + 5)

        var texts: [String] = []
        var deltas: [String] = [""]
        for output in outputs {
            switch output {
            case .delta(let segment, let text):
                #expect(segment == texts.count, "增量文字應該屬於目前還沒確定的那一段")
                deltas[deltas.count - 1] += text
            case .finished(let segment, let text, _):
                #expect(segment == texts.count, "段號應該從 0 開始、一次加 1")
                #expect(text == normalized(deltas[deltas.count - 1]), "一段確定時的文字，就是這一段所有增量接起來")
                texts.append(text)
                deltas.append("")
            case .amended(let segment, let text):
                #expect(segment == texts.count - 1, "只會補在最近確定的那一段")
                if segment == texts.count - 1 { texts[segment] = text }
            case .extended(let segment, let text):
                #expect(segment == texts.count - 1, "只會併回最近確定的那一段")
                // 尾巴原本是以下一段的增量送出的：併回去之後，接起來要等於新的整段文字
                if segment == texts.count - 1 {
                    #expect(text == texts[segment] + " " + normalized(deltas[deltas.count - 1]))
                    texts[segment] = text
                }
                deltas[deltas.count - 1] = ""
            }
        }
        #expect(normalized(texts.joined(separator: " ")) == original.joined(separator: " "))
        #expect(segmenter.pendingText == "")
    }
}
