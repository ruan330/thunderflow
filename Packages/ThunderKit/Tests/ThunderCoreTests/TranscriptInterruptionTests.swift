import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 逐字稿標示錄音中斷（DESIGN.md 5.4 節：「逐字稿在中斷處標示」）：日誌裡原因是 sleep、deviceLost、outputChanged、
/// captureStalled 的缺口，在段落與 `transcript.md` 的那個位置標出原因與大約沒有錄到多久。一般的缺口照舊。
@Suite("逐字稿：錄音中斷的標示")
struct TranscriptInterruptionTests {
    private func source(_ text: String, at time: Double, seg: Int) -> JournalEntry {
        .source(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
    }

    private func translation(_ text: String, at time: Double, seg: Int) -> JournalEntry {
        .translation(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
    }

    private func interruption(at time: Double, _ reason: GapReason, lost: Double) -> JournalEntry {
        .gap(.interruption(at: AudioTime(seconds: time), lostSeconds: lost, reason: reason))
    }

    @Test("錄音中斷的地方結束段落；中斷標在下一個段落前面，帶原因與沒有錄到多久")
    func interruptionStartsANewBlock() {
        let entries: [JournalEntry] = [
            source("First part.", at: 10, seg: 0), translation("第一部分。", at: 11, seg: 0),
            interruption(at: 12, .sleep, lost: 845.25),
            source("Second part.", at: 13, seg: 1), translation("第二部分。", at: 14, seg: 1),
        ]

        let blocks = TranscriptBlocks.build(from: entries).blocks

        #expect(blocks.map(\.segments) == [[0], [1]])
        #expect(blocks.first?.interruptionsBefore == [])
        #expect(blocks.last?.interruptionsBefore == [TranscriptInterruption(at: 12, reason: .sleep, lostSeconds: 845.25)])
        #expect(blocks.allSatisfy { $0.interruptionsAfter.isEmpty })
    }

    @Test("一般的缺口（網路、跟不上、引擎停了）照舊：不結束段落，也不標示", arguments: [GapReason.network, .backpressure, .engineStopped])
    func ordinaryGapsAreNotMarked(reason: GapReason) {
        let entries: [JournalEntry] = [
            source("First part.", at: 10, seg: 0),
            .gap(AudioGap(from: AudioTime(seconds: 11), to: AudioTime(seconds: 12), reason: reason)),
            source("Second part.", at: 13, seg: 1),
        ]

        let blocks = TranscriptBlocks.build(from: entries).blocks

        #expect(blocks.map(\.segments) == [[0, 1]])
        #expect(blocks.allSatisfy { $0.interruptionsBefore.isEmpty && $0.interruptionsAfter.isEmpty })
    }

    @Test("最後一段話之後才中斷（之後沒有人說話）：標在最後一個段落後面")
    func trailingInterruptionGoesAfterTheLastBlock() {
        let entries: [JournalEntry] = [
            source("Only part.", at: 10, seg: 0), interruption(at: 40, .deviceLost, lost: 3.2),
        ]

        let blocks = TranscriptBlocks.build(from: entries).blocks

        #expect(blocks.count == 1)
        #expect(blocks.first?.interruptionsBefore == [])
        #expect(blocks.first?.interruptionsAfter == [TranscriptInterruption(at: 40, reason: .deviceLost, lostSeconds: 3.2)])
    }

    @Test(
        "標示的文字：原因，加上大約沒有錄到多久（秒、分鐘、小時）",
        arguments: [
            (GapReason.sleep, 845.25, "〔錄音中斷：電腦睡眠，約 14 分鐘沒有錄到〕"),
            (.deviceLost, 3.2, "〔錄音中斷：收音裝置不見了，約 3 秒沒有錄到〕"),
            (.outputChanged, 0.4, "〔錄音中斷：輸出裝置換了，不到 1 秒沒有錄到〕"),
            (.captureStalled, 75, "〔錄音中斷：收音停了，約 1 分鐘沒有錄到〕"),
            (.sleep, 7_500, "〔錄音中斷：電腦睡眠，約 2 小時 5 分鐘沒有錄到〕"),
        ] as [(GapReason, Double, String)])
    func labels(reason: GapReason, lost: Double, expected: String) {
        #expect(TranscriptInterruption(at: 0, reason: reason, lostSeconds: lost).label == expected)
    }

    @Test("blocks.jsonl：有中斷的段落多一個欄位，讀回來一樣；沒有中斷的段落和以前一模一樣")
    func blocksFileRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")
        let blocks = [
            TranscriptBlock(id: 0, start: 8, en: "First part.", zh: "第一部分。", segments: [0]),
            TranscriptBlock(
                id: 1, start: 11, en: "Second part.", segments: [1],
                interruptionsBefore: [TranscriptInterruption(at: 12, reason: .sleep, lostSeconds: 845.25)],
                interruptionsAfter: [TranscriptInterruption(at: 40, reason: .deviceLost, lostSeconds: 3.2)]),
        ]

        try TranscriptBlocks.write(blocks, to: url)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == #"{"id":0,"start":8,"en":"First part.","zh":"第一部分。","segments":[0],"marked":false}"#)
        #expect(
            lines.last
                == #"{"id":1,"start":11,"en":"Second part.","zh":"","segments":[1],"marked":false,"before":[{"at":12,"why":"sleep","lost":845.25}],"after":[{"at":40,"why":"deviceLost","lost":3.2}]}"#
        )
        #expect(try TranscriptBlocks.read(url) == blocks)
    }

    @Test("transcript.md 在中斷的位置標示：段落前面、或最後一個段落後面")
    func markdownShowsTheInterruptions() {
        let meta = SessionMeta(title: "測試", startedAt: Date(timeIntervalSince1970: 1_796_178_600), state: .complete)
        let blocks = [
            TranscriptBlock(id: 0, start: 8, en: "First part.", zh: "第一部分。", segments: [0]),
            TranscriptBlock(
                id: 1, start: 11, en: "Second part.", zh: "第二部分。", segments: [1],
                interruptionsBefore: [TranscriptInterruption(at: 12, reason: .sleep, lostSeconds: 845.25)],
                interruptionsAfter: [TranscriptInterruption(at: 40, reason: .deviceLost, lostSeconds: 3.2)]),
        ]

        let text = TranscriptMarkdown.render(meta: meta, blocks: blocks, timeZone: TimeZone(identifier: "Asia/Taipei")!)

        #expect(
            text.hasSuffix(
                "\n### 00:00:08\nFirst part.\n\n第一部分。\n"
                    + "\n〔錄音中斷：電腦睡眠，約 14 分鐘沒有錄到〕\n"
                    + "\n### 00:00:11\nSecond part.\n\n第二部分。\n"
                    + "\n〔錄音中斷：收音裝置不見了，約 3 秒沒有錄到〕\n"))
    }
}
