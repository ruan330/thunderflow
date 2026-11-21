import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 結束處理的最後一步：摘要與自動命名（DESIGN.md 5.8 節）。文字模型一律用照劇本回答的假模型。
@Suite("結束處理：摘要與自動命名", .timeLimit(.minutes(2)))
struct SessionSummaryStepTests {
    /// 文字模型的回答：章節沒有照時間排，其中兩個超出 45 秒的錄音。
    private static let answer = """
        {"title":"用 Bedrock 打造 Agent","one_liner":"介紹 Agent 的能力，並示範如何在主控台建立。",
         "key_points":["Agent 可以呼叫工具","Agent 能記住事情"],
         "chapters":[{"start_sec":34,"title":"示範","summary":"在主控台實際操作。"},
                     {"start_sec":8,"title":"開場","summary":"Agent 是什麼。"},
                     {"start_sec":300,"title":"超出錄音長度","summary":"不應該留下來。"},
                     {"start_sec":-5,"title":"負的時間","summary":""}],
         "glossary":[{"en":"agent","zh":"代理程式"}],"action_items":[]}
        """

    /// `answer` 整理之後應該存下來的摘要。
    private static let summary = SessionSummary(
        title: "用 Bedrock 打造 Agent", oneLiner: "介紹 Agent 的能力，並示範如何在主控台建立。",
        keyPoints: ["Agent 可以呼叫工具", "Agent 能記住事情"],
        chapters: [
            .init(startSec: 8, title: "開場", summary: "Agent 是什麼。"),
            .init(startSec: 34, title: "示範", summary: "在主控台實際操作。"),
        ],
        glossary: [.init(en: "agent", zh: "代理程式")], actionItems: [])

    private static let secondAnswer = """
        {"title":"另一個標題","one_liner":"第二版的總結。","key_points":["第二版的重點"],"chapters":[],"glossary":[],"action_items":["追蹤後續"]}
        """

    private static let allSteps = ["blocks", "transcript", "audio", "publish", "summary"]
    private static let stepsBeforeSummary = ["blocks", "transcript", "audio", "publish"]

    private struct Roots {
        let tmp: TemporaryDirectory
        var working: URL { tmp.url.appendingPathComponent("Working", isDirectory: true) }
        var library: URL { tmp.url.appendingPathComponent("Library", isDirectory: true) }

        init() throws { tmp = try TemporaryDirectory() }

        func finalizer(
            _ model: ScriptedTextModel?, configure: (inout FinalizationOptions) -> Void = { _ in }
        ) -> SessionFinalizer {
            var options = FinalizationOptions(libraryRoot: library)
            options.textModel = model
            configure(&options)
            return SessionFinalizer(options: options)
        }
    }

    /// 回答 `answer` 的模型，分成好幾片送回來。
    private func goodModel(_ text: String = answer) -> ScriptedTextModel {
        ScriptedTextModel { _, _ in .text(text, pieces: 7) }
    }

    private func finalize(
        _ session: SessionDirectory, with finalizer: SessionFinalizer, log: ProgressLog? = nil
    ) async throws -> SessionDirectory {
        try await withDeadline(.seconds(30)) {
            try await finalizer.finalize(session) { step, directory in log?.record(step, directory) }
        }
    }

    private func regenerate(_ session: SessionDirectory, with finalizer: SessionFinalizer) async throws -> SessionDirectory {
        try await withDeadline(.seconds(30)) { try await finalizer.regenerateSummary(session) }
    }

    @Test("送給文字模型的請求：一次請求、設定的模型、結構化輸出的格式、台灣用語的指示，內容是場次資訊、重點標記與附時間的英文段落")
    func request() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working) {
            $0.event = "AWS re:Invent 2026"
            $0.speaker = "Jane Doe"
            $0.keywords = ["AgentCore", "Bedrock"]
        }
        let model = goodModel()

        _ = try await finalize(session, with: roots.finalizer(model) { $0.summaryModel = "gpt-6.1-terra" })

        let requests = model.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.model == "gpt-6.1-terra")
        #expect(request.schema == SessionSummary.schema)
        for phrase in ["台灣繁體中文", "台灣用語", "保留英文原文", "空陣列", "錄音長度之內"] {
            #expect(request.instructions.contains(phrase), "指示裡沒有「\(phrase)」")
        }
        let expectedInput = """
            場次資訊
            標題：Building Agents with Bedrock
            活動：AWS re:Invent 2026
            講者：Jane Doe
            關鍵詞：AgentCore、Bedrock
            錄音長度：00:00:45（45 秒）

            重點標記：00:00:34

            逐字稿（每行開頭是這一段開始的時間）
            [00:00:08] Welcome everyone. Today we talk about agents. They can call tools, and remember things.
            [00:00:34] Let's look at a demo. First, open the console.
            """
        #expect(request.input == expectedInput)
        // 預設的模型
        #expect(FinalizationOptions(libraryRoot: roots.library).summaryModel == "gpt-6-luna")
    }

    @Test("摘要存成 summary.json 與 summary.md，一句話總結記進 session.json；超出錄音長度的章節剔除，其餘依時間排序")
    func writesTheSummary() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let log = ProgressLog()

        let published = try await finalize(session, with: roots.finalizer(goodModel()), log: log)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == Self.allSteps)
        #expect(meta.failedSteps.isEmpty)
        #expect(meta.oneLiner == "介紹 Agent 的能力，並示範如何在主控台建立。")
        #expect(meta.title == Finished.title)
        let stored = try SessionSummary.read(published.summaryDataURL)
        #expect(stored == Self.summary)
        #expect(stored.chapters.map(\.startSec) == [8, 34])
        #expect(
            try String(contentsOf: published.summaryURL, encoding: .utf8)
                == SummaryMarkdown.render(meta: meta, summary: Self.summary))
        #expect(
            filePaths(in: published.url) == [
                ".thunderflow/blocks.jsonl", ".thunderflow/journal.jsonl", ".thunderflow/session.json",
                ".thunderflow/summary.json", "recording.m4a", "summary.md", "transcript.md",
            ])
        #expect(log.steps == FinalizationStep.allCases)
        #expect(log.all.last?.state == .complete)
        #expect(log.all.last?.completedSteps == Self.allSteps)
        // 已經有標題的場次不會被改名
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(published.url.lastPathComponent.hasSuffix(" " + Finished.title))
    }

    @Test("摘要做完之後再做一次結束處理：不再呼叫文字模型、不回報任何步驟、成品不變；重做摘要這一步，結果一樣")
    func summaryIsIdempotent() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let model = goodModel()
        let finalizer = roots.finalizer(model)
        let published = try await finalize(session, with: finalizer)
        let before = try folderSnapshot(roots.library)
        let log = ProgressLog()

        let again = try await finalize(published, with: finalizer, log: log)

        #expect(again == published)
        #expect(log.steps.isEmpty)
        #expect(model.requests.count == 1)
        #expect(try folderSnapshot(roots.library) == before)

        // 當成摘要沒有做過
        var meta = try published.loadMeta()
        meta.completedSteps.removeAll { $0 == "summary" }
        meta.state = .finalizing
        try published.saveMeta(meta)
        let redone = try await finalize(published, with: finalizer, log: log)

        #expect(redone == published)
        #expect(log.steps == [.summary])
        #expect(model.requests.count == 2)
        #expect(try folderSnapshot(roots.library) == before)
    }

    @Test(
        "摘要失敗：場次照樣完成，只記下「摘要失敗」；其他成品不受影響",
        arguments: ["文字模型回錯誤", "回答不是 JSON", "回答是空的摘要", "文字模型一直沒有回應"])
    func summaryFailure(reason: String) async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let model = ScriptedTextModel { _, _ in
            switch reason {
            case "文字模型回錯誤": .failure(.http(status: 500, message: "server error"))
            case "回答不是 JSON": .text("抱歉，我沒辦法整理這份逐字稿。")
            case "回答是空的摘要": .text("{}")
            default: .stall
            }
        }
        let log = ProgressLog()

        let published = try await finalize(
            session, with: roots.finalizer(model) { $0.summaryTimeout = .milliseconds(100) }, log: log)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == Self.stepsBeforeSummary)
        #expect(meta.failedSteps == ["summary"])
        #expect(meta.oneLiner.isEmpty)
        #expect(model.requests.count == 1)
        #expect(log.steps == FinalizationStep.allCases)
        #expect(log.all.last?.state == .complete)
        #expect(published.url.deletingLastPathComponent().path == roots.library.path)
        #expect(!fileExists(published.summaryURL))
        #expect(!fileExists(published.summaryDataURL))
        #expect(try TranscriptBlocks.read(published.blocksURL) == Finished.blocks)
        #expect(fileExists(published.transcriptURL))
        #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 45) < 0.2)
    }

    @Test("摘要失敗之後可以重試：再做一次結束處理，或重新產生摘要，成功後清掉「摘要失敗」")
    func retryAfterFailure() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let failing = roots.finalizer(ScriptedTextModel { _, _ in .failure(.http(status: 503, message: "offline")) })
        let working = roots.finalizer(goodModel())
        let first = try await finalize(try Finished.makeSession(in: roots.working, title: "第一場"), with: failing)
        let second = try await finalize(try Finished.makeSession(in: roots.working, title: "第二場"), with: failing)
        #expect(try first.loadMeta().failedSteps == ["summary"])
        #expect(try second.loadMeta().failedSteps == ["summary"])

        let log = ProgressLog()
        let retried = try await finalize(first, with: working, log: log)
        let regenerated = try await regenerate(second, with: working)

        #expect(log.steps == [.summary])
        #expect(retried == first)
        #expect(regenerated == second)
        for published in [first, second] {
            let meta = try published.loadMeta()
            #expect(meta.state == .complete)
            #expect(meta.failedSteps.isEmpty)
            #expect(meta.completedSteps == Self.allSteps)
            #expect(meta.oneLiner == Self.summary.oneLiner)
            #expect(try SessionSummary.read(published.summaryDataURL) == Self.summary)
            #expect(fileExists(published.summaryURL))
        }
    }

    @Test(
        "不需要摘要時略過，不算失敗，也不呼叫文字模型",
        arguments: ["沒有文字模型", "關閉了自動摘要", "逐字稿沒有任何文字"])
    func summarySkipped(reason: String) async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(
            in: roots.working, journal: reason == "逐字稿沒有任何文字" ? [] : Finished.journal)
        let model = goodModel()
        let finalizer = roots.finalizer(reason == "沒有文字模型" ? nil : model) {
            $0.summarize = reason != "關閉了自動摘要"
        }
        let log = ProgressLog()

        let published = try await finalize(session, with: finalizer, log: log)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == Self.stepsBeforeSummary)
        #expect(meta.failedSteps.isEmpty)
        #expect(model.requests.isEmpty)
        #expect(log.steps == FinalizationStep.allCases)
        #expect(!fileExists(published.summaryURL))
        #expect(!fileExists(published.summaryDataURL))
    }

    @Test("沒有命名的場次：用摘要的標題命名，資料夾跟著改名，逐字稿與摘要的標題也是新的")
    func autoNaming() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working, title: "")
        let model = goodModel()
        let log = ProgressLog()

        let published = try await finalize(session, with: roots.finalizer(model), log: log)

        let meta = try published.loadMeta()
        #expect(meta.title == "用 Bedrock 打造 Agent")
        #expect(meta.state == .complete)
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(published.url.lastPathComponent.hasSuffix(" 用 Bedrock 打造 Agent"))
        // 發布時還叫「未命名」，摘要之後回報的是改名後的位置
        let entries = log.all
        #expect(entries.map(\.step) == FinalizationStep.allCases)
        #expect(entries.first { $0.step == .publish }?.directory.url.lastPathComponent.hasSuffix(" 未命名") == true)
        #expect(entries.last?.directory == published)
        #expect(SessionLibrary.list(root: roots.library).map(\.directory) == [published])
        #expect(try FileManager.default.contentsOfDirectory(atPath: roots.library.path) == [published.url.lastPathComponent])
        // 沒有標題的場次，請求裡沒有「標題」那一行
        #expect(model.requests.first?.input.contains("標題：") == false)
        let transcript = try String(contentsOf: published.transcriptURL, encoding: .utf8)
        let summary = try String(contentsOf: published.summaryURL, encoding: .utf8)
        #expect(transcript == TranscriptMarkdown.render(meta: meta, blocks: Finished.blocks))
        #expect(transcript.hasPrefix("# 用 Bedrock 打造 Agent\n"))
        #expect(summary.hasPrefix("# 用 Bedrock 打造 Agent\n"))
    }

    @Test("自動命名：標題裡不能當檔名的字元只在資料夾名稱裡換掉；名稱已經被占用時加上序號")
    func autoNamingCollisions() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let answer = Self.answer.replacingOccurrences(of: "用 Bedrock 打造 Agent", with: "AI/ML: 入門")
        let taken = SessionLibrary.folderName(for: SessionMeta(title: "AI/ML: 入門", startedAt: Finished.startedAt))
        try FileManager.default.createDirectory(
            at: roots.library.appendingPathComponent(taken, isDirectory: true), withIntermediateDirectories: true)
        let session = try Finished.makeSession(in: roots.working, title: "")

        let published = try await finalize(session, with: roots.finalizer(goodModel(answer)))

        #expect(try published.loadMeta().title == "AI/ML: 入門")
        #expect(taken.hasSuffix(" AI ML 入門"))
        #expect(published.url.lastPathComponent == taken + " 2")
    }

    @Test("重新產生摘要：覆寫 summary.md 與 summary.json、更新一句話總結；已經有標題的場次不改名")
    func regenerateOverwrites() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let published = try await finalize(session, with: roots.finalizer(goodModel()))
        let model = goodModel(Self.secondAnswer)

        // 重新產生是使用者明確要求的：不看「自動摘要」的設定
        let location = try await regenerate(published, with: roots.finalizer(model) { $0.summarize = false })

        #expect(location == published)
        #expect(model.requests.count == 1)
        let meta = try published.loadMeta()
        #expect(meta.title == Finished.title)
        #expect(meta.oneLiner == "第二版的總結。")
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == Self.allSteps)
        let second = SessionSummary(
            title: "另一個標題", oneLiner: "第二版的總結。", keyPoints: ["第二版的重點"], actionItems: ["追蹤後續"])
        #expect(try SessionSummary.read(published.summaryDataURL) == second)
        #expect(
            try String(contentsOf: published.summaryURL, encoding: .utf8)
                == SummaryMarkdown.render(meta: meta, summary: second))
    }

    @Test("重新產生摘要失敗：丟出錯誤，原有的摘要與 session.json 都不動")
    func regenerateFailureKeepsTheOldSummary() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let published = try await finalize(session, with: roots.finalizer(goodModel()))
        let before = try folderSnapshot(roots.library)

        await #expect(throws: TextModelError.http(status: 500, message: "boom")) {
            try await roots.finalizer(ScriptedTextModel { _, _ in .failure(.http(status: 500, message: "boom")) })
                .regenerateSummary(published)
        }
        await #expect(throws: SessionSummaryError.notJSON) {
            try await roots.finalizer(ScriptedTextModel(answer: "不是 JSON")).regenerateSummary(published)
        }
        await #expect(throws: SessionFinalizerError.missingTextModel) {
            try await roots.finalizer(nil).regenerateSummary(published)
        }

        #expect(try folderSnapshot(roots.library) == before)
    }

    @Test("重新產生摘要：逐字稿沒有任何文字時丟出錯誤，不呼叫文字模型")
    func regenerateNeedsATranscript() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working, journal: [])
        let model = goodModel()
        let published = try await finalize(session, with: roots.finalizer(nil))

        await #expect(throws: SessionFinalizerError.emptyTranscript) {
            try await roots.finalizer(model).regenerateSummary(published)
        }
        #expect(model.requests.isEmpty)
    }

    @Test("沒有命名、第一次摘要又失敗的場次：重新產生摘要成功後補上標題，資料夾改名，回傳新的位置")
    func regenerateNamesAnUntitledSession() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working, title: "")
        let unnamed = try await finalize(
            session, with: roots.finalizer(ScriptedTextModel { _, _ in .failure(.http(status: 503, message: "offline")) }))
        #expect(unnamed.url.lastPathComponent.hasSuffix(" 未命名"))
        #expect(try unnamed.loadMeta().failedSteps == ["summary"])

        let renamed = try await regenerate(unnamed, with: roots.finalizer(goodModel()))

        let meta = try renamed.loadMeta()
        #expect(meta.title == "用 Bedrock 打造 Agent")
        #expect(meta.failedSteps.isEmpty)
        #expect(meta.completedSteps == Self.allSteps)
        #expect(renamed.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(!fileExists(unnamed.url))
        #expect(SessionLibrary.list(root: roots.library).map(\.directory) == [renamed])
    }
}
