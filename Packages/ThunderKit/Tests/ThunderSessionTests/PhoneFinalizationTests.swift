import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 手機上的結束處理（DESIGN.md 5.10 節，D36）：段落、逐字稿、合併錄音都不需要網路，手機做完這三步就交給 Mac，
/// 發布與摘要由 Mac 接著做（`FinalizationOptions.lastStep`）。
@Suite("手機上的結束處理：做到合併錄音為止，狀態維持 finalizing（D36）", .timeLimit(.minutes(2)))
struct PhoneFinalizationTests {
    private struct Roots {
        let tmp: TemporaryDirectory
        var phone: URL { tmp.url.appendingPathComponent("Phone", isDirectory: true) }
        var library: URL { tmp.url.appendingPathComponent("Library", isDirectory: true) }

        init() throws { tmp = try TemporaryDirectory() }

        func finalizer(lastStep: FinalizationStep?) -> SessionFinalizer {
            var options = FinalizationOptions(libraryRoot: library)
            options.lastStep = lastStep
            return SessionFinalizer(options: options)
        }
    }

    @discardableResult
    private func finalize(
        _ session: SessionDirectory, with finalizer: SessionFinalizer, log: ProgressLog? = nil
    ) async throws -> SessionDirectory {
        try await withDeadline(.seconds(30)) {
            try await finalizer.finalize(session) { step, directory in log?.record(step, directory) }
        }
    }

    @Test("做到 audio 為止：段落、逐字稿、錄音檔做好，CAF 分段刪掉；資料夾留在原處、不建立 Library；狀態維持 finalizing")
    func stopsAfterAudio() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.phone)
        let log = ProgressLog()

        let result = try await finalize(session, with: roots.finalizer(lastStep: .audio), log: log)

        #expect(result == session)
        #expect(log.steps == [.blocks, .transcript, .audio])
        #expect(log.all.map(\.state) == [.finalizing, .finalizing, .finalizing])
        let meta = try session.loadMeta()
        #expect(meta.state == .finalizing)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio"])
        #expect(meta.failedSteps.isEmpty)
        #expect(meta.durationSeconds == 45)
        #expect(try TranscriptBlocks.read(session.blocksURL) == Finished.blocks)
        #expect(
            try String(contentsOf: session.transcriptURL, encoding: .utf8)
                == TranscriptMarkdown.render(meta: meta, blocks: Finished.blocks))
        #expect(abs(try RecordingMerger.duration(of: session.recordingURL) - 45) < 0.2)
        #expect(
            filePaths(in: session.url) == [
                ".thunderflow/blocks.jsonl", ".thunderflow/journal.jsonl", ".thunderflow/session.json", "recording.m4a",
                "transcript.md",
            ])
        #expect(!fileExists(roots.library))
    }

    @Test(
        "做到哪一步就停在那一步：之後的步驟不做也不回報，狀態維持 finalizing",
        arguments: [FinalizationStep.blocks, .transcript, .audio, .publish])
    func stopsAtTheGivenStep(last: FinalizationStep) async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.phone)
        let log = ProgressLog()

        let result = try await finalize(session, with: roots.finalizer(lastStep: last), log: log)

        let done = Array(FinalizationStep.allCases.prefix { $0 != last }) + [last]
        #expect(log.steps == done)
        let meta = try result.loadMeta()
        #expect(meta.completedSteps == done.map(\.rawValue))
        #expect(meta.state == .finalizing)
        #expect(log.all.allSatisfy { $0.state == .finalizing })
    }

    @Test("做到 audio 為止、這三步都已經做完的場次再做一次：什麼都不做，狀態仍然是 finalizing，檔案一個位元組都不變")
    func nothingLeftStaysFinalizing() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.phone)
        let phone = roots.finalizer(lastStep: .audio)
        try await finalize(session, with: phone)
        let before = try folderSnapshot(session.url)
        let log = ProgressLog()

        let again = try await finalize(session, with: phone, log: log)

        #expect(again == session)
        #expect(log.steps.isEmpty)
        #expect(try session.loadMeta().state == .finalizing)
        #expect(try folderSnapshot(session.url) == before)
    }

    @Test("手機做到 audio 之後，用預設的選項（全部的步驟）接著做：只做發布與摘要，成品和一次做完的一樣")
    func defaultOptionsContinueAfterAudio() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.phone)
        try await finalize(session, with: roots.finalizer(lastStep: .audio))
        let log = ProgressLog()

        #expect(FinalizationOptions(libraryRoot: roots.library).lastStep == nil)
        let published = try await finalize(session, with: roots.finalizer(lastStep: nil), log: log)

        #expect(log.steps == [.publish, .summary])
        try Finished.expectPublished(published, in: roots.library)
    }

    @Test("停在最後一步（摘要）和沒有指定一樣：做完全部的步驟，狀態變成 complete")
    func lastStepSummaryFinishesEverything() async throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let session = try Finished.makeSession(in: roots.phone)
        let log = ProgressLog()

        let published = try await finalize(session, with: roots.finalizer(lastStep: .summary), log: log)

        #expect(log.steps == FinalizationStep.allCases)
        try Finished.expectPublished(published, in: roots.library)
    }
}
