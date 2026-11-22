import Foundation
import Testing
import ThunderCore
import ThunderTestKit

@Suite("session.json 記下這一場開始時有沒有開暫定譯文（估算費用用）")
struct SessionMetaProvisionalTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_796_000_000)

    private func makeDirectory(in tmp: TemporaryDirectory) throws -> SessionDirectory {
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("場次", isDirectory: true))
        try directory.create()
        return directory
    }

    @Test("記下開了或沒開：存檔再讀回來不變")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        for provisional in [true, false] {
            var meta = SessionMeta(startedAt: Self.startedAt, state: .finalizing)
            meta.provisionalTranslation = provisional
            try directory.saveMeta(meta)
            #expect(try directory.loadMeta().provisionalTranslation == provisional)
        }
    }

    @Test("還沒有這個欄位的舊檔案：讀得進來，不知道有沒有開（nil），格式版本仍是 1")
    func olderFiles() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let older = """
            {
              "schemaVersion": 1,
              "id": "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC",
              "startedAt": "2026-11-30T00:53:20Z",
              "state": "complete",
              "billedAudioSeconds": 3480
            }
            """
        try older.write(to: directory.metaURL, atomically: true, encoding: .utf8)

        let meta = try directory.loadMeta()
        #expect(meta.provisionalTranslation == nil)
        #expect(meta.billedAudioSeconds == 3_480)
        #expect(SessionMeta.currentSchemaVersion == 1)
    }

    @Test("不知道有沒有開（nil）時不寫這個欄位：檔案和以前完全一樣")
    func unknownIsNotWritten() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        try directory.saveMeta(SessionMeta(startedAt: Self.startedAt, state: .finalizing))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.metaURL))
        let json = try #require(object as? [String: Any])
        #expect(json["provisionalTranslation"] == nil)
    }
}
