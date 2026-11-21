import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 結束處理（DESIGN.md 5.7 節）的前四步：基本段落、逐字稿、合併錄音、發布。都不需要網路。
@Suite("結束處理：段落、逐字稿、合併錄音、發布", .timeLimit(.minutes(2)))
struct SessionFinalizerTests {
    /// 每個測試自己的工作目錄與 Library。
    private struct Roots {
        let tmp: TemporaryDirectory
        var working: URL { tmp.url.appendingPathComponent("Working", isDirectory: true) }
        var library: URL { tmp.url.appendingPathComponent("Library", isDirectory: true) }
        var finalizer: SessionFinalizer { SessionFinalizer(options: FinalizationOptions(libraryRoot: library)) }

        init() throws { tmp = try TemporaryDirectory() }
    }

    private func finalize(
        _ session: SessionDirectory, with finalizer: SessionFinalizer, log: ProgressLog? = nil
    ) async throws -> SessionDirectory {
        try await withDeadline(.seconds(30)) {
            try await finalizer.finalize(session) { step, directory in log?.record(step, directory) }
        }
    }

    @Test("跑完全部步驟：段落、逐字稿、錄音檔齊全，CAF 分段刪掉，資料夾搬進 Library，狀態是 complete")
    func producesEverythingAndPublishes() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)

        let published = try await finalize(session, with: roots.finalizer)

        try Finished.expectPublished(published, in: roots.library)
        let transcript = try String(contentsOf: published.transcriptURL, encoding: .utf8)
        #expect(transcript.hasPrefix("# Building Agents with Bedrock\n"))
        #expect(transcript.contains("\n### 00:00:08\nWelcome everyone. Today we talk about agents."))
        #expect(transcript.contains("\n### 00:00:34 ⚑\nLet's look at a demo."))
        // 工作目錄裡不再有這一場，Library 裡只有它
        #expect(filePaths(in: roots.working).isEmpty)
        #expect(SessionLibrary.list(root: roots.library).map(\.directory) == [published])
    }

    @Test("每做完一步就記進 session.json 並回報；回報的是資料夾當下的位置；最後一步才變成 complete")
    func reportsProgressAfterEachStep() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let log = ProgressLog()

        let published = try await finalize(session, with: roots.finalizer, log: log)

        let entries = log.all
        #expect(entries.map(\.step) == [.blocks, .transcript, .audio, .publish, .summary])
        #expect(entries.map(\.directory) == [session, session, session, published, published])
        #expect(
            entries.map(\.completedSteps) == [
                ["blocks"], ["blocks", "transcript"], ["blocks", "transcript", "audio"],
                ["blocks", "transcript", "audio", "publish"],
                // 沒有文字模型：摘要被略過，不算完成也不算失敗
                ["blocks", "transcript", "audio", "publish"],
            ])
        #expect(entries.map(\.state) == [.finalizing, .finalizing, .finalizing, .finalizing, .complete])
        #expect(published != session)
    }

    @Test("已經做完的場次再做一次：成品一個位元組都不變")
    func finalizingAgainChangesNothing() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let published = try await finalize(session, with: roots.finalizer)
        let before = try folderSnapshot(roots.library)
        #expect(before.count == 5)

        let again = try await finalize(published, with: roots.finalizer)

        #expect(again == published)
        #expect(try folderSnapshot(roots.library) == before)
        #expect(filePaths(in: roots.working).isEmpty)
    }

    @Test(
        "每一步重做，結果都一樣（不變條件 4）",
        arguments: [FinalizationStep.blocks, .transcript, .audio, .publish])
    func redoingAStepGivesTheSameResult(step: FinalizationStep) async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let published = try await finalize(session, with: roots.finalizer)
        let before = try folderSnapshot(roots.library)

        // 當成這一步沒有做過
        var meta = try published.loadMeta()
        meta.completedSteps.removeAll { $0 == step.rawValue }
        meta.state = .finalizing
        try published.saveMeta(meta)
        let log = ProgressLog()
        let again = try await finalize(published, with: roots.finalizer, log: log)

        #expect(again == published)
        #expect(log.steps == [step, .summary])
        #expect(try folderSnapshot(roots.library) == before)
        try Finished.expectPublished(again, in: roots.library)
    }

    @Test(
        "在任何一步之後中斷，再呼叫一次會從下一步接著做完，做過的步驟不重做",
        arguments: [FinalizationStep.blocks, .transcript, .audio, .publish])
    func resumesAfterAnInterruption(stopAfter: FinalizationStep) async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        let finalizer = roots.finalizer
        let log = ProgressLog()

        // 這一步回報之後就取消工作（相當於 App 在這時候被關掉）
        let running = LockedValue<Task<SessionDirectory, any Error>?>(nil)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate { break }
            return try await finalizer.finalize(session) { step, directory in
                log.record(step, directory)
                if step == stopAfter { running.value?.cancel() }
            }
        }
        running.withValue { $0 = task }
        open.yield()
        let interrupted = try await withDeadline(.seconds(30)) { await task.result }
        #expect(throws: CancellationError.self) { try interrupted.get() }

        let done = Array(FinalizationStep.allCases.prefix { $0 != stopAfter }) + [stopAfter]
        #expect(log.steps == done)
        let current = try #require(log.all.last).directory
        let meta = try current.loadMeta()
        #expect(meta.state == .finalizing)
        #expect(meta.completedSteps == done.map(\.rawValue))

        let published = try await finalize(current, with: finalizer, log: log)

        #expect(log.steps == FinalizationStep.allCases)
        try Finished.expectPublished(published, in: roots.library)
        #expect(filePaths(in: roots.working).isEmpty)
    }

    @Test("真的錄一場（RecordingSession 加上會分段的腳本引擎）之後做結束處理")
    func finalizesARecordedSession() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        // 每 3 秒一段：字幕在第 1.6、4.6、7.6……秒出現，一分鐘共 20 段
        let engine = ScriptedEngine(.segments(every: 3))
        let (session, directory) = try Fixture.makeSession(in: roots.working, engine: engine) { $0.segmentDuration = 25 }
        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 60)
        let recorded = try await withDeadline(.seconds(30)) { try await session.finish() }
        #expect(try recordedSegments(directory).count == 3)

        let published = try await finalize(directory, with: roots.finalizer)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.id == recorded.id)
        #expect(meta.integrity.untranslatedSegments == 0)
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: recorded))
        #expect(published.url.lastPathComponent.hasSuffix(" 測試場次"))

        // 段落：滿 20 秒之後遇到 3 秒的停頓就結束
        let blocks = try TranscriptBlocks.read(published.blocksURL)
        #expect(blocks.map(\.segments) == [Array(0...7), Array(8...15), Array(16...19)])
        #expect(blocks.map(\.start) == [0, 23.6, 47.6])
        #expect(blocks.first?.en == (1...8).map(ScriptedEngine.sourceText).joined(separator: " "))
        #expect(blocks.first?.zh == (1...8).map(ScriptedEngine.translationText).joined(separator: " "))
        #expect(
            try String(contentsOf: published.transcriptURL, encoding: .utf8)
                == TranscriptMarkdown.render(meta: meta, blocks: blocks))

        // 錄音：三個 CAF 分段合成一個 m4a，長度不變
        #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 60) < 0.2)
        #expect(!fileExists(published.audioDirectoryURL))
        #expect(filePaths(in: roots.working).isEmpty)
    }

    @Test("沒有聲音也沒有字幕的場次：照樣做完並發布，不產生錄音檔")
    func emptySession() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working, title: "", journal: [], audio: [])

        let published = try await finalize(session, with: roots.finalizer)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio", "publish"])
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(published.url.lastPathComponent.hasSuffix(" 未命名"))
        #expect(try TranscriptBlocks.read(published.blocksURL).isEmpty)
        #expect(
            try String(contentsOf: published.transcriptURL, encoding: .utf8)
                == TranscriptMarkdown.render(meta: meta, blocks: []))
        #expect(
            filePaths(in: published.url) == [
                ".thunderflow/blocks.jsonl", ".thunderflow/journal.jsonl", ".thunderflow/session.json", "transcript.md",
            ])
        #expect(!fileExists(published.audioDirectoryURL))
    }

    @Test("當機復原的場次：最後一段沒有結束、日誌最後一行寫到一半，照樣做完")
    func finalizesARecoveredSession() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let unfinished = [
            Finished.source(" And one more", at: 43, seg: 6, end: false),
            Finished.source(" thing", at: 43.5, seg: 6, end: false),
        ]
        let session = try Finished.makeSession(in: roots.working, journal: Finished.journal + unfinished) {
            $0.state = .recording
            $0.durationSeconds = 0
        }
        let handle = try FileHandle(forWritingTo: session.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"k\":\"src\",\"t\":44,\"x\":\"hal".utf8))
        try handle.close()

        // 還沒復原：不能做結束處理
        await #expect(throws: SessionFinalizerError.stillRecording) {
            try await roots.finalizer.finalize(session)
        }
        #expect(!fileExists(session.blocksURL))

        let interrupted = try #require(try SessionRecovery.findInterrupted(in: roots.working).first)
        try SessionRecovery.recover(interrupted)
        let published = try await finalize(session, with: roots.finalizer)

        let meta = try published.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.recovered)
        #expect(abs(meta.durationSeconds - 45) < 0.001)
        #expect(meta.integrity.untranslatedSegments == 2)
        let blocks = try TranscriptBlocks.read(published.blocksURL)
        #expect(blocks.map(\.segments) == [[0, 1, 2, 3], [4, 5, 6]])
        #expect(blocks.last?.en == "Let's look at a demo. First, open the console. And one more thing")
        #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 45) < 0.2)
    }

    @Test("session.json 的錄音長度是 0 時補上實際的長度（逐字稿的資訊列跟著更新）；已經有值就不動")
    func fillsInAMissingDuration() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let unknown = try Finished.makeSession(in: roots.working, title: "長度未知") { $0.durationSeconds = 0 }
        let known = try Finished.makeSession(in: roots.working, title: "長度已知") { $0.durationSeconds = 44.5 }

        let first = try await finalize(unknown, with: roots.finalizer)
        let second = try await finalize(known, with: roots.finalizer)

        #expect(abs(try first.loadMeta().durationSeconds - 45) < 0.001)
        let transcript = try String(contentsOf: first.transcriptURL, encoding: .utf8)
        #expect(transcript.split(separator: "\n").dropFirst().first?.contains(" · 0:45 · ") == true)
        #expect(try second.loadMeta().durationSeconds == 44.5)
    }

    @Test("合併出來的長度和 CAF 分段不一致：丟出錯誤，CAF 一個都不刪，不留下 m4a，已完成的成品不受影響")
    func keepsSegmentsWhenTheMergedDurationIsWrong() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        // 第二個分段檔被截斷：檔頭還是寫著 15 秒，實際只有一半
        let damaged = try #require(try RecordingFiles.segments(in: session.audioDirectoryURL).last)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: damaged.url.path)[.size] as? NSNumber)
        #expect(truncate(damaged.url.path, off_t(size.intValue / 2)) == 0)
        let log = ProgressLog()

        do {
            _ = try await finalize(session, with: roots.finalizer, log: log)
            Issue.record("應該丟出錯誤")
        } catch let error as SessionFinalizerError {
            guard case .durationMismatch(let recorded, let merged) = error else {
                Issue.record("不是預期的錯誤：\(error)")
                return
            }
            #expect(abs(recorded - 45) < 0.01)
            #expect(merged < recorded - 0.2)
        }

        #expect(log.steps == [.blocks, .transcript])
        #expect(
            filePaths(in: session.url) == [
                ".thunderflow/audio/000.caf", ".thunderflow/audio/001.caf", ".thunderflow/blocks.jsonl",
                ".thunderflow/journal.jsonl", ".thunderflow/session.json", "transcript.md",
            ])
        let meta = try session.loadMeta()
        #expect(meta.state == .finalizing)
        #expect(meta.completedSteps == ["blocks", "transcript"])
        #expect(try TranscriptBlocks.read(session.blocksURL) == Finished.blocks)
        #expect(SessionLibrary.list(root: roots.library).isEmpty)
    }

    @Test("合併中斷後重做：已經合併好的 recording.m4a 不會被比較短的結果蓋掉；不完整的 m4a 會重新合併")
    func redoingTheMergeNeverShortensTheRecording() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }

        // 上次已經合併好，而且 CAF 刪到一半
        let half = try Finished.makeSession(in: roots.working, title: "刪到一半", audio: [15, 15, 15])
        let segments = try RecordingFiles.segments(in: half.audioDirectoryURL)
        #expect(segments.count == 3)
        _ = try RecordingMerger.merge(segments: segments, to: half.recordingURL)
        if let first = segments.first { try FileManager.default.removeItem(at: first.url) }
        let complete = try Data(contentsOf: half.recordingURL)

        let first = try await finalize(half, with: roots.finalizer)

        #expect(try Data(contentsOf: first.recordingURL) == complete)
        #expect(abs(try RecordingMerger.duration(of: first.recordingURL) - 45) < 0.2)
        #expect(!fileExists(first.audioDirectoryURL))
        #expect(try first.loadMeta().state == .complete)

        // 留下來的 m4a 只有前 15 秒：重新合併
        let short = try Finished.makeSession(in: roots.working, title: "不完整", audio: [15, 15, 15])
        let prefix = Array(try RecordingFiles.segments(in: short.audioDirectoryURL).prefix(1))
        _ = try RecordingMerger.merge(segments: prefix, to: short.recordingURL)

        let second = try await finalize(short, with: roots.finalizer)

        #expect(abs(try RecordingMerger.duration(of: second.recordingURL) - 45) < 0.2)
        #expect(!fileExists(second.audioDirectoryURL))
    }

    @Test("發布：資料夾以開始時間與標題命名，不合法的字元換掉；重名時加上序號；Library 不存在會自動建立")
    func publishNaming() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        #expect(!fileExists(roots.library))
        var published: [SessionDirectory] = []
        for _ in 0..<3 {
            let session = try Finished.makeSession(in: roots.working, title: "AI/ML: What's Next?", audio: [1])
            published.append(try await finalize(session, with: roots.finalizer))
        }

        let name = SessionLibrary.folderName(for: SessionMeta(title: "AI/ML: What's Next?", startedAt: Finished.startedAt))
        #expect(name.hasSuffix(" AI ML What's Next?"))
        #expect(published.map(\.url.lastPathComponent) == [name, name + " 2", name + " 3"])
        #expect(published.allSatisfy { $0.url.deletingLastPathComponent().path == roots.library.path })
        // 標題本身不變，只有資料夾名稱換掉不合法的字元
        #expect(try published.map { try $0.loadMeta().title } == Array(repeating: "AI/ML: What's Next?", count: 3))
        #expect(SessionLibrary.list(root: roots.library).count == 3)
    }

    @Test("已經在 Library 裡的場次不會再搬（包含使用者自己整理進子資料夾的）")
    func sessionsAlreadyInTheLibraryStayPut() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let top = try Finished.makeSession(in: roots.library, title: "第一層")
        let nested = try Finished.makeSession(
            in: roots.library.appendingPathComponent("2026 re:Invent", isDirectory: true), title: "子資料夾")

        let stayedOnTop = try await finalize(top, with: roots.finalizer)
        let stayedNested = try await finalize(nested, with: roots.finalizer)

        #expect(stayedOnTop == top)
        #expect(stayedNested == nested)

        for session in [top, nested] {
            let meta = try session.loadMeta()
            #expect(meta.state == .complete)
            #expect(meta.completedSteps == ["blocks", "transcript", "audio", "publish"])
            #expect(fileExists(session.recordingURL))
        }
    }

    @Test("某一步失敗：丟出錯誤，已經完成的成品不受影響；問題排除後再呼叫一次就做完")
    func aFailedStepLeavesEarlierResultsIntact() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.working)
        // Library 的位置被一個檔案占住，建不出資料夾
        let blocked = roots.tmp.url.appendingPathComponent("blocked")
        try Data("我是檔案".utf8).write(to: blocked)
        let failing = SessionFinalizer(
            options: FinalizationOptions(libraryRoot: blocked.appendingPathComponent("Library", isDirectory: true)))
        let log = ProgressLog()

        await #expect(throws: (any Error).self) {
            try await failing.finalize(session) { step, directory in log.record(step, directory) }
        }

        #expect(log.steps == [.blocks, .transcript, .audio])
        let meta = try session.loadMeta()
        #expect(meta.state == .finalizing)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio"])
        #expect(try TranscriptBlocks.read(session.blocksURL) == Finished.blocks)
        #expect(abs(try RecordingMerger.duration(of: session.recordingURL) - 45) < 0.2)

        let published = try await finalize(session, with: roots.finalizer, log: log)

        #expect(log.steps == FinalizationStep.allCases)
        try Finished.expectPublished(published, in: roots.library)
    }

    @Test("處理中可以開始新的場次：兩場同時做結束處理互不影響，同名的資料夾各有各的名稱")
    func twoSessionsAtOnce() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let first = try Finished.makeSession(in: roots.working)
        let second = try Finished.makeSession(in: roots.working)
        let finalizer = roots.finalizer

        let (a, b) = try await withDeadline(.seconds(30)) {
            async let a = finalizer.finalize(first)
            async let b = finalizer.finalize(second)
            return try await (a, b)
        }

        let name = SessionLibrary.folderName(for: SessionMeta(title: Finished.title, startedAt: Finished.startedAt))
        #expect(Set([a.url.lastPathComponent, b.url.lastPathComponent]) == [name, name + " 2"])
        for published in [a, b] {
            #expect(try published.loadMeta().state == .complete)
            #expect(try TranscriptBlocks.read(published.blocksURL) == Finished.blocks)
            #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 45) < 0.2)
        }
        #expect(Set(SessionLibrary.list(root: roots.library).map(\.id)) == Set([try a.loadMeta().id, try b.loadMeta().id]))
        #expect(filePaths(in: roots.working).isEmpty)
    }
}
