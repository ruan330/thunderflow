import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// M2 的事件模型：字幕帶段號，句子進行中另有暫定譯文。
@Suite("RecordingSession：段號與暫定譯文")
struct SegmentEventTests {
    @Test("暫定譯文不寫進日誌；英文與中文定稿帶著段號寫進去")
    func provisionalTranslationsAreNotJournaled() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        // 每 2 秒一段：每一段依序送出暫定譯文、英文、中文定稿
        let engine = ScriptedEngine(.segments(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 10)
        try await withDeadline(.seconds(10)) { try await session.finish() }

        let journal = try JournalReader.read(directory.journalURL)
        #expect(journal.sources.map(\.text) == (1...5).map(ScriptedEngine.sourceText))
        #expect(journal.sources.map(\.segment) == [0, 1, 2, 3, 4])
        #expect(journal.translations.map(\.text) == (1...5).map(ScriptedEngine.translationText))
        #expect(journal.translations.map(\.segment) == [0, 1, 2, 3, 4])
        // 日誌裡只有英文與中文定稿，沒有暫定譯文
        #expect(journal.entries.count == 10)
        let everyText = journal.sources.map(\.text) + journal.translations.map(\.text)
        #expect(!everyText.contains { $0.hasPrefix("暫定") })
    }

    @Test("不分段的引擎照舊：日誌裡沒有段號")
    func enginesWithoutSegmentsStillWork() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 6)
        try await withDeadline(.seconds(10)) { try await session.finish() }

        let journal = try JournalReader.read(directory.journalURL)
        #expect(journal.sources.count == 3)
        #expect(journal.sources.allSatisfy { $0.segment == nil })
        let text = try String(contentsOf: directory.journalURL, encoding: .utf8)
        #expect(!text.contains("\"seg\""))
    }
}
