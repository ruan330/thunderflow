import Foundation
import Testing
import ThunderCore
import ThunderTestKit

// 整句定稿（DESIGN.md 5.6.2 節）：一句說完之後整句重翻，譯文放在這一句的最後一段，並記下這一句從哪一段開始。
// 英文也帶著它屬於第幾句，給畫面把同一句的段合成一個段落。

/// 一段確定的英文。
private func src(_ text: String, at time: Double, seg: Int, sentence: Int? = nil) -> JournalEntry {
    .source(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg, sentence: sentence))
}

/// 一段自己的中文定稿。
private func tr(_ text: String, at time: Double, seg: Int) -> JournalEntry {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
}

/// 第 `sentence` 句（第 `first` 段到第 `seg` 段）的整句定稿。
private func sentenceFinal(_ text: String, at time: Double, first: Int, seg: Int, sentence: Int) -> JournalEntry {
    .translation(
        CaptionText(
            text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg, sentence: sentence, sentenceStart: first))
}

private func pause(at time: Double) -> [JournalEntry] {
    [.paused(at: AudioTime(seconds: time)), .resumed(at: AudioTime(seconds: time))]
}

@Suite("日誌：整句定稿")
struct JournalSentenceTests {
    @Test("句子的編號與整句定稿的起點，寫進去再讀出來都一樣；多的欄位放在最後（sen、first），沒有時格式和以前完全一樣")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let entries: [JournalEntry] = [
            src("And the reason for that is", at: 10.5, seg: 4, sentence: 2),
            tr("原因是", at: 11.5, seg: 4),
            src("that it never occurred.", at: 12.5, seg: 5, sentence: 2),
            sentenceFinal("原因是它從來沒有出現過。", at: 13.25, first: 4, seg: 5, sentence: 2),
        ]
        let writer = try JournalWriter(url: url)
        for entry in entries { try writer.append(entry) }
        writer.close()

        let contents = try JournalReader.read(url)
        #expect(contents.entries == entries)
        #expect(contents.skippedLineCount == 0)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                #"{"k":"src","t":10.5,"x":"And the reason for that is","end":true,"seg":4,"sen":2}"#,
                #"{"k":"tr","t":11.5,"x":"原因是","end":true,"seg":4}"#,
                #"{"k":"src","t":12.5,"x":"that it never occurred.","end":true,"seg":5,"sen":2}"#,
                #"{"k":"tr","t":13.25,"x":"原因是它從來沒有出現過。","end":true,"seg":5,"sen":2,"first":4}"#,
            ])
    }

    @Test("句子的編號或起點不是整數時當成沒有，這一筆的其他欄位照常讀")
    func invalidFields() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        try Data(Array(#"{"k":"tr","t":1.5,"x":"一","end":true,"seg":3,"sen":"two","first":1.5}"#.utf8) + [0x0A]).write(to: url)

        let contents = try JournalReader.read(url)
        #expect(contents.entries == [.translation(CaptionText(text: "一", kind: .segmentEnd, at: AudioTime(seconds: 1.5), segment: 3))])
    }
}

@Suite("基本段落：整句定稿")
struct TranscriptBlocksSentenceTests {
    @Test("一句被切成好幾段：段落的中文用整句定稿、不用各段的定稿；這一句的最後一段沒有自己的定稿，也不算沒翻到")
    func usesSentenceFinal() {
        let result = TranscriptBlocks.build(from: [
            src("And the reason for that is", at: 10.5, seg: 0, sentence: 0),
            tr("原因是", at: 11.5, seg: 0),
            src("that", at: 12.5, seg: 1, sentence: 0),
            tr("原因是人體藝術", at: 13.5, seg: 1),
            src("it never occurred.", at: 14.5, seg: 2, sentence: 0),
            sentenceFinal("原因是它從來沒有出現過。", at: 15.5, first: 0, seg: 2, sentence: 0),
            src("Next sentence.", at: 17.5, seg: 3, sentence: 1),
            sentenceFinal("下一句。", at: 18.5, first: 3, seg: 3, sentence: 1),
        ])

        #expect(result.blocks.count == 1)
        #expect(result.blocks.first?.en == "And the reason for that is that it never occurred. Next sentence.")
        #expect(result.blocks.first?.zh == "原因是它從來沒有出現過。下一句。")
        #expect(result.blocks.first?.segments == [0, 1, 2, 3])
        #expect(result.untranslatedSegments == 0)
    }

    @Test("同一句重新翻譯（併入晚到的尾巴）：以最後一筆整句定稿為準")
    func latestSentenceFinalWins() {
        let result = TranscriptBlocks.build(from: [
            src("We can make sure", at: 10.5, seg: 0, sentence: 0),
            tr("我們可以確保", at: 11.5, seg: 0),
            src("each character is unique.", at: 12.5, seg: 1, sentence: 0),
            sentenceFinal("我們可以確保每個字元都是唯一的。", at: 13.5, first: 0, seg: 1, sentence: 0),
            src("each character is a unique token.", at: 14.5, seg: 1, sentence: 0),
            sentenceFinal("我們可以確保每個字元都是獨立的 token。", at: 15.5, first: 0, seg: 1, sentence: 0),
        ])

        #expect(result.blocks.map(\.zh) == ["我們可以確保每個字元都是獨立的 token。"])
        #expect(result.untranslatedSegments == 0)
    }

    @Test("一句沒有整句定稿（還沒翻完就結束）：用各段自己的定稿，沒有定稿的段算沒翻到")
    func fallsBackToSegmentFinals() {
        let result = TranscriptBlocks.build(from: [
            src("And the reason for that is", at: 10.5, seg: 0, sentence: 0),
            tr("原因是", at: 11.5, seg: 0),
            src("that it never occurred.", at: 12.5, seg: 1, sentence: 0),
        ])

        #expect(result.blocks.map(\.zh) == ["原因是"])
        #expect(result.untranslatedSegments == 1)
    }

    @Test("一句跨過段落的邊界（中間按了暫停）：整句的中文放在這一句最後一段所在的段落，前面那幾段不重複")
    func sentenceAcrossBlocks() {
        let result = TranscriptBlocks.build(
            from: [
                src("So when you ask", at: 10.5, seg: 0, sentence: 0),
                tr("所以當你問", at: 11.5, seg: 0),
            ] + pause(at: 12) + [
                src("the next question.", at: 13.5, seg: 1, sentence: 0),
                sentenceFinal("所以當你問下一個問題時。", at: 14.5, first: 0, seg: 1, sentence: 0),
            ])

        #expect(result.blocks.map(\.segments) == [[0], [1]])
        #expect(result.blocks.map(\.zh) == ["", "所以當你問下一個問題時。"])
        #expect(result.untranslatedSegments == 0)
    }
}
