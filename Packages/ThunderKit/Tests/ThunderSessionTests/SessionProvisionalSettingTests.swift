import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

@Suite("錄音：開始時的暫定譯文設定記進 session.json，整場不變")
struct SessionProvisionalSettingTests {
    @Test("開始時記下有沒有開暫定譯文；結束之後 session.json 裡仍是開始時的設定")
    func recordedAtStart() async throws {
        for provisional in [true, false] {
            let tmp = try TemporaryDirectory()
            defer { tmp.remove() }
            let engine = ScriptedEngine(.captions(every: 2))
            let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) {
                $0.provisionalTranslation = provisional
            }
            #expect(try directory.loadMeta().provisionalTranslation == provisional, "開始時")

            session.start()
            try await feedInLockstep(session, engine: engine, seconds: 2)
            let meta = try await withDeadline(.seconds(30)) { try await session.finish() }

            #expect(meta.provisionalTranslation == provisional, "finish() 回傳的")
            #expect(try directory.loadMeta().provisionalTranslation == provisional, "結束之後的檔案")
        }
    }

    @Test("沒有設定（nil）時不記：和以前的場次一樣")
    func notRecordedWhenUnknown() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (_, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 2)))
        #expect(try directory.loadMeta().provisionalTranslation == nil)
    }
}
