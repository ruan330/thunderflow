import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 效能預算：過去錄音的清單、打開一場、按下停止到逐字稿可讀（DESIGN.md 9.8 節）。
@Suite(
    "效能預算 Perf：過去錄音與結束處理",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct LibraryPerfTests {
    private static let english = String(
        repeating: "Amazon Bedrock AgentCore makes it easier to build and run production-ready agents at scale. ", count: 6)
    private static let chinese = String(repeating: "Amazon Bedrock AgentCore 讓大規模打造與執行可上線的代理程式變得更容易。", count: 6)

    @Test("載入 500 場的清單：只讀每一場的 session.json")
    func scan500() throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        for index in 0..<500 {
            var meta = SessionMeta(
                title: "第 \(index) 場：AgentCore 與 Bedrock 的新功能", startedAt: Date(timeIntervalSince1970: 1_796_000_000 + Double(index) * 7_200),
                state: .complete, source: "系統音訊", engine: "gpt-live-transcribe＋gpt-6-luna", durationSeconds: 3_600)
            meta.event = "AWS re:Invent 2026"
            meta.speaker = "Jane Doe"
            meta.keywords = (0..<20).map { "Keyword \($0)" }
            meta.oneLiner = "這一場介紹 AgentCore 的執行環境、閘道與記憶，以及怎麼把代理程式安全地推上線。"
            meta.completedSteps = ["blocks", "transcript", "audio", "publish", "summary"]
            let directory = SessionDirectory(url: tmp.url.appendingPathComponent("2026-11-21 \(10_000 + index) 第 \(index) 場", isDirectory: true))
            try directory.create()
            try directory.saveMeta(meta)
            // 成品（清單不讀它們）
            try directory.writeText(String(repeating: Self.english, count: 30), to: directory.transcriptURL)
        }

        var count = 0
        let elapsed = Perf.measure(runs: 5) { count = SessionLibrary.list(root: tmp.url).count }

        #expect(count == 500)
        let milliseconds = elapsed.seconds * 1_000
        let budget = try budgets.maximum("library.scan500.milliseconds.max")
        print("量測：載入 500 場的清單 \(milliseconds) ms（預算 \(budget) ms）")
        #expect(milliseconds <= budget, "\(milliseconds) ms，預算 \(budget) ms")
    }

    @Test("打開一場 8 小時的紀錄：讀出場次資訊、段落與摘要")
    func openSession8h() throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("session", isDirectory: true))
        try directory.create()
        try directory.saveMeta(SessionMeta(title: "八小時", startedAt: Date(timeIntervalSince1970: 1_796_000_000), state: .complete, durationSeconds: 28_800))
        // 8 小時：每 40 秒一個段落，共 720 個段落，每個段落約 90 個英文字與對應的中文
        let blocks = (0..<720).map {
            TranscriptBlock(
                id: $0, start: Double($0) * 40, en: Self.english, zh: Self.chinese, segments: Array($0 * 10..<$0 * 10 + 10),
                marked: $0 % 50 == 0)
        }
        try TranscriptBlocks.write(blocks, to: directory.blocksURL)
        let summary = SessionSummary(
            title: "八小時的工作坊", oneLiner: "一整天的 AgentCore 工作坊。",
            keyPoints: (0..<10).map { "重點 \($0)：\(Self.chinese)" },
            chapters: (0..<24).map { .init(startSec: Double($0) * 1_200, title: "第 \($0) 章", summary: Self.chinese) },
            glossary: (0..<30).map { .init(en: "Term \($0)", zh: "術語 \($0)") },
            actionItems: (0..<5).map { "待辦 \($0)" })
        try summary.write(to: directory.summaryDataURL)

        var opened = 0
        let elapsed = try Perf.measure(runs: 5) {
            _ = try directory.loadMeta()
            opened = try TranscriptBlocks.read(directory.blocksURL).count
            _ = try SessionSummary.read(directory.summaryDataURL)
        }

        #expect(opened == 720)
        let milliseconds = elapsed.seconds * 1_000
        let budget = try budgets.maximum("library.openSession8h.milliseconds.max")
        print("量測：打開 8 小時的場次 \(milliseconds) ms（預算 \(budget) ms）")
        #expect(milliseconds <= budget, "\(milliseconds) ms，預算 \(budget) ms")
    }

    @Test("按下停止到逐字稿可讀：8 小時的日誌（約 10 萬行）做成段落與 transcript.md")
    func stopToTranscript() async throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let template = SessionDirectory(url: tmp.url.appendingPathComponent("template", isDirectory: true))
        try template.create()
        try template.saveMeta(
            SessionMeta(title: "八小時", startedAt: Date(timeIntervalSince1970: 1_796_000_000), state: .finalizing, durationSeconds: 28_800))
        // 每 4 秒一段，共 7,200 段：每段 12 筆增量英文、一筆一段結束、一筆中文定稿
        let journal = try JournalWriter(url: template.journalURL)
        for segment in 0..<7_200 {
            let start = Double(segment) * 4
            for word in 0..<12 {
                try journal.append(
                    .source(CaptionText(text: " word\(word)", kind: .delta, at: AudioTime(seconds: start + Double(word) * 0.3), segment: segment)))
            }
            try journal.append(
                .source(CaptionText(text: "Twelve words in this segment, spoken in about four seconds.", kind: .segmentEnd, at: AudioTime(seconds: start + 3.8), segment: segment)))
            try journal.append(
                .translation(CaptionText(text: "這一段大約四秒，有十二個英文字。", kind: .segmentEnd, at: AudioTime(seconds: start + 5), segment: segment)))
        }
        journal.close()

        // 每一次都從同樣的場次開始（結束處理會改動資料夾），取中位數
        var times: [Double] = []
        var blockCount = 0
        for run in 0..<3 {
            let session = SessionDirectory(url: tmp.url.appendingPathComponent("run-\(run)", isDirectory: true))
            try FileManager.default.copyItem(at: template.url, to: session.url)
            let finalizer = SessionFinalizer(options: FinalizationOptions(libraryRoot: tmp.url.appendingPathComponent("Library-\(run)")))
            let readable = LockedValue<ContinuousClock.Instant?>(nil)
            let started = ContinuousClock.now
            let published = try await withDeadline(.seconds(60)) {
                try await finalizer.finalize(session) { step, _ in
                    if step == .transcript { readable.withValue { $0 = ContinuousClock.now } }
                }
            }
            let at = try #require(readable.value)
            times.append((at - started).seconds)
            blockCount = try TranscriptBlocks.read(published.blocksURL).count
            #expect(FileManager.default.fileExists(atPath: published.transcriptURL.path))
        }

        #expect(blockCount > 0)
        let milliseconds = times.sorted()[1] * 1_000
        let budget = try budgets.maximum("session.stopToTranscript.milliseconds.max")
        print("量測：8 小時的日誌做成逐字稿 \(milliseconds) ms（預算 \(budget) ms）")
        #expect(milliseconds <= budget, "\(milliseconds) ms（\(times.map { Int($0 * 1_000) }) ms），預算 \(budget) ms")
    }
}
