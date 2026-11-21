import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 段號（M2）：一段英文和它的中文用同一個號碼，寫進日誌之後，逐字稿的中英對照不用再靠時間估計。
@Suite("日誌：段號")
struct JournalSegmentTests {
    private func write(_ entries: [JournalEntry], to url: URL) throws {
        let writer = try JournalWriter(url: url)
        for entry in entries { try writer.append(entry) }
        writer.close()
    }

    @Test("段號寫進去再讀出來都一樣；沒有段號的紀錄照舊")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let entries: [JournalEntry] = [
            .source(CaptionText(text: " Hello", kind: .delta, at: AudioTime(seconds: 12.25), segment: 0)),
            .source(CaptionText(text: "Hello world.", kind: .segmentEnd, at: AudioTime(seconds: 12.5), segment: 0)),
            .translation(CaptionText(text: "哈囉，世界。", kind: .segmentEnd, at: AudioTime(seconds: 13.5), segment: 0)),
            .source(CaptionText(text: "Next one.", kind: .segmentEnd, at: AudioTime(seconds: 15), segment: 1)),
            .translation(CaptionText(text: "下一句。", kind: .segmentEnd, at: AudioTime(seconds: 16), segment: 1)),
            .source(CaptionText(text: "no segment", kind: .segmentEnd, at: AudioTime(seconds: 20))),
            .translation(CaptionText(text: "沒有段號", kind: .segmentEnd, at: AudioTime(seconds: 21))),
        ]

        try write(entries, to: url)
        let contents = try JournalReader.read(url)

        #expect(contents.entries == entries)
        #expect(contents.skippedLineCount == 0)
        let sourceSegments = contents.entries.compactMap { entry -> Int?? in
            if case .source(let text) = entry { text.segment } else { nil }
        }
        let translationSegments = contents.entries.compactMap { entry -> Int?? in
            if case .translation(let text) = entry { text.segment } else { nil }
        }
        #expect(sourceSegments == [0, 0, 1, nil])
        #expect(translationSegments == [0, 1, nil])
    }

    @Test("有段號時多一個 seg 欄位，放在最後；沒有段號時格式和以前完全一樣")
    func lineFormat() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        try write(
            [
                .source(CaptionText(text: "Hello", kind: .segmentEnd, at: AudioTime(seconds: 12.5), segment: 3)),
                .translation(CaptionText(text: "你好", kind: .segmentEnd, at: AudioTime(seconds: 13.25), segment: 3)),
                .source(CaptionText(text: " more", kind: .delta, at: AudioTime(seconds: 14), segment: 4)),
                .source(CaptionText(text: "old style", kind: .segmentEnd, at: AudioTime(seconds: 15))),
            ], to: url)

        let expected = """
            {"k":"src","t":12.5,"x":"Hello","end":true,"seg":3}
            {"k":"tr","t":13.25,"x":"你好","end":true,"seg":3}
            {"k":"src","t":14,"x":" more","seg":4}
            {"k":"src","t":15,"x":"old style","end":true}

            """
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
    }

    @Test("第 0 段的段號也會寫出來")
    func segmentZeroIsWritten() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        try write([.translation(CaptionText(text: "第一段", kind: .segmentEnd, at: AudioTime(seconds: 2), segment: 0))], to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"k\":\"tr\",\"t\":2,\"x\":\"第一段\",\"end\":true,\"seg\":0}\n")
    }

    @Test("文件記載的格式讀得懂：有 seg 的行讀出段號；加入段號之前寫下的行，段號是 nil")
    func readsDocumentedFormat() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let text = """
            {"k":"src","t":12.5,"x":"Hello","end":true,"seg":3}
            {"k":"tr","t":13.25,"x":"你好","end":true,"seg":3}
            {"k":"src","t":20,"x":"Before segments","end":true}
            {"k":"tr","t":21,"x":"加入段號之前","end":true}

            """
        try Data(text.utf8).write(to: url)

        let contents = try JournalReader.read(url)

        #expect(
            contents.entries == [
                .source(CaptionText(text: "Hello", kind: .segmentEnd, at: AudioTime(seconds: 12.5), segment: 3)),
                .translation(CaptionText(text: "你好", kind: .segmentEnd, at: AudioTime(seconds: 13.25), segment: 3)),
                .source(CaptionText(text: "Before segments", kind: .segmentEnd, at: AudioTime(seconds: 20))),
                .translation(CaptionText(text: "加入段號之前", kind: .segmentEnd, at: AudioTime(seconds: 21))),
            ])
        #expect(contents.skippedLineCount == 0)
    }

    @Test("seg 不是整數的行：其他欄位照樣讀進來，段號當成沒有")
    func toleratesAMalformedSegmentNumber() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        try Data("{\"k\":\"src\",\"t\":1,\"x\":\"Hi\",\"end\":true,\"seg\":\"three\"}\n".utf8).write(to: url)

        let contents = try JournalReader.read(url)

        #expect(contents.entries == [.source(CaptionText(text: "Hi", kind: .segmentEnd, at: AudioTime(seconds: 1)))])
        #expect(contents.skippedLineCount == 0)
    }
}
