import Foundation
import Testing
import ThunderCore
import ThunderTestKit

private func date(_ iso8601: String) -> Date {
    ISO8601DateFormatter().date(from: iso8601) ?? Date(timeIntervalSince1970: 0)
}

private let taipei = TimeZone(identifier: "Asia/Taipei") ?? .gmt

@Suite("transcript.md：中英對照的逐字稿")
struct TranscriptMarkdownTests {
    @Test("輸出與設計文件的範例完全一致：標題、資訊列，每個段落是時間、英文、空一行、中文；重點標記加上旗標")
    func matchesTheDocumentedFormat() {
        let meta = SessionMeta(
            title: "Building Agents with Bedrock", startedAt: date("2026-12-02T02:30:00Z"), state: .finalizing,
            source: "系統音訊", durationSeconds: 3_492)
        let blocks = [
            TranscriptBlock(
                id: 0, start: 12.4, en: "So today we're going to talk about building production-ready agents...",
                zh: "今天我們要談的是如何打造可以上線的 Agent……", segments: [0, 1]),
            TranscriptBlock(
                id: 1, start: 95, en: "Amazon Bedrock AgentCore gives you three core components.",
                zh: "Amazon Bedrock AgentCore 提供 3 個核心元件。", segments: [2], marked: true),
            TranscriptBlock(id: 2, start: 2_537, en: "This one has no translation yet.", zh: "", segments: [3]),
        ]

        let expected = """
            # Building Agents with Bedrock
            2026-12-02 10:30 · 58:12 · 系統音訊

            ### 00:00:12
            So today we're going to talk about building production-ready agents...

            今天我們要談的是如何打造可以上線的 Agent……

            ### 00:01:35 ⚑
            Amazon Bedrock AgentCore gives you three core components.

            Amazon Bedrock AgentCore 提供 3 個核心元件。

            ### 00:42:17
            This one has no translation yet.

            """
        #expect(TranscriptMarkdown.render(meta: meta, blocks: blocks, timeZone: taipei) == expected)
    }

    @Test("沒有標題的場次寫成「未命名」；沒有來源說明時省略；超過一小時的時間與長度")
    func untitledAndLongSessions() {
        let meta = SessionMeta(title: "  ", startedAt: date("2026-11-27T06:00:00Z"), durationSeconds: 6_125)
        let blocks = [TranscriptBlock(id: 0, start: 3_723.9, en: "Past the first hour.", zh: "超過一小時了。")]

        let expected = """
            # 未命名
            2026-11-27 14:00 · 1:42:05

            ### 01:02:03
            Past the first hour.

            超過一小時了。

            """
        #expect(TranscriptMarkdown.render(meta: meta, blocks: blocks, timeZone: taipei) == expected)
    }

    @Test("沒有任何段落時只有標題與資訊列")
    func noBlocks() {
        let meta = SessionMeta(title: "空的一場", startedAt: date("2026-12-02T02:30:00Z"), source: "MacBook Pro 麥克風")

        #expect(
            TranscriptMarkdown.render(meta: meta, blocks: [], timeZone: taipei)
                == "# 空的一場\n2026-12-02 10:30 · 0:00 · MacBook Pro 麥克風\n")
    }

    @Test("開始時間用指定時區的當地時間")
    func usesTheGivenTimeZone() throws {
        let meta = SessionMeta(title: "Keynote", startedAt: date("2026-12-02T02:30:00Z"), durationSeconds: 60)
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))

        #expect(
            TranscriptMarkdown.render(meta: meta, blocks: [], timeZone: losAngeles)
                == "# Keynote\n2026-12-01 18:30 · 1:00\n")
    }
}

@Suite("Timecode：把秒數排成給人看的時間")
struct TimecodeTests {
    @Test(
        "時間位置是 HH:MM:SS，不足一秒捨去",
        arguments: [
            (0, "00:00:00"), (12.9, "00:00:12"), (59.999, "00:00:59"), (95, "00:01:35"), (3_600, "01:00:00"),
            (86_399, "23:59:59"), (360_000, "100:00:00"), (-5, "00:00:00"),
        ] as [(Double, String)])
    func clock(seconds: Double, expected: String) {
        #expect(Timecode.clock(seconds) == expected)
    }

    @Test(
        "長度不到一小時是 M:SS，一小時以上是 H:MM:SS，四捨五入到秒",
        arguments: [
            (0, "0:00"), (59.4, "0:59"), (59.5, "1:00"), (65, "1:05"), (3_492, "58:12"), (3_599.6, "1:00:00"),
            (6_125, "1:42:05"), (36_000, "10:00:00"), (-1, "0:00"),
        ] as [(Double, String)])
    func duration(seconds: Double, expected: String) {
        #expect(Timecode.duration(seconds) == expected)
    }
}

@Suite("場次資料夾：結束處理的成品")
struct SessionOutputsTests {
    @Test("成品的位置：錄音、逐字稿、摘要在資料夾裡，段落與摘要的資料在 .thunderflow 裡")
    func layout() {
        let directory = SessionDirectory(url: URL(fileURLWithPath: "/tmp/Library/2026-12-02 1030 Keynote", isDirectory: true))
        let root = directory.url.path

        #expect(directory.recordingURL.path == root + "/recording.m4a")
        #expect(directory.transcriptURL.path == root + "/transcript.md")
        #expect(directory.summaryURL.path == root + "/summary.md")
        #expect(directory.blocksURL.path == root + "/.thunderflow/blocks.jsonl")
        #expect(directory.summaryDataURL.path == root + "/.thunderflow/summary.json")
    }

    @Test("文字檔以 UTF-8 原子寫入：整個檔案換掉，不留暫存檔")
    func writesTextAtomically() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("session"))
        try directory.create()

        try directory.writeText("# 很長的第一版\n" + String(repeating: "內容\n", count: 200), to: directory.transcriptURL)
        try directory.writeText("# 第二版\n", to: directory.transcriptURL)

        #expect(try String(contentsOf: directory.transcriptURL, encoding: .utf8) == "# 第二版\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == [".thunderflow", "transcript.md"])
    }
}
