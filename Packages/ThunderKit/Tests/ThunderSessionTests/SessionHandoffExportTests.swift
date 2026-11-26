import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 寫一個文字檔，需要的資料夾一起建立。
func writeFile(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// 手機把場次交到收件匣（DESIGN.md 5.10 節，D36）：複製到 `<收件匣>/<場次 id>/`，最後才寫 `.thunderflow/handoff.json`。
@Suite("交給 Mac：複製到收件匣，最後才寫 handoff.json（D36）", .timeLimit(.minutes(1)))
struct SessionHandoffExportTests {
    @Test("複製到「收件匣/場次 id/」：每個檔案內容一樣；handoff.json 列出其他每個檔案的相對路徑與大小；手機上的那一份不動")
    func copiesEveryFileAndListsIt() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        let id = try session.loadMeta().id
        let original = try folderSnapshot(session.url)

        let exported = try SessionHandoff.export(session, to: roots.inbox)

        #expect(exported.path == roots.inbox.appendingPathComponent(id.uuidString).path)
        var copied = try folderSnapshot(exported)
        let manifestData = copied.removeValue(forKey: ".thunderflow/handoff.json")
        #expect(copied == original)
        let manifest = try JSONDecoder().decode(HandoffManifest.self, from: try #require(manifestData))
        #expect(manifest.version == 1)
        #expect(manifest.id == id)
        #expect(manifest.from == "iPhone")
        #expect(manifest.files.map(\.path) == PhoneSession.files)
        for file in manifest.files {
            #expect(file.size == Int64(original[file.path]?.count ?? -1), "\(file.path)")
        }
        // 手機上的那一份由呼叫端在交好之後刪掉
        #expect(try folderSnapshot(session.url) == original)
    }

    @Test("handoff.json 的格式和 DESIGN.md 5.10 節一樣：version、id（場次 id 的字串）、from、files（path、size）")
    func manifestFormat() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        let id = try session.loadMeta().id

        let folder = try SessionHandoff.export(session, to: roots.inbox, from: "iPhone")

        let object = try ManifestFile.read(in: folder)
        #expect(Set(object.keys) == ["version", "id", "from", "files"])
        #expect(object["version"] as? Int == 1)
        #expect(object["id"] as? String == id.uuidString)
        #expect(object["from"] as? String == "iPhone")
        let files = try #require(object["files"] as? [[String: Any]])
        #expect(files.map { Set($0.keys) } == Array(repeating: ["path", "size"], count: PhoneSession.files.count))
        #expect(files.first?["path"] as? String == ".thunderflow/blocks.jsonl")
        #expect(files.first?["size"] as? Int == (try Data(contentsOf: session.blocksURL)).count)
    }

    @Test("名稱以「.」開頭的雜檔（.DS_Store、iCloud 的暫存檔、寫到一半的暫存檔）不複製也不列；子資料夾裡的檔案照樣交出去")
    func skipsHiddenJunk() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        for path in [
            ".DS_Store", ".thunderflow/.DS_Store", ".recording.m4a.icloud", ".thunderflow/.session.json.6F1C.tmp",
            "workshop/.DS_Store",
        ] {
            try writeFile("雜檔", at: session.url.appendingPathComponent(path))
        }
        try writeFile("<html></html>", at: session.url.appendingPathComponent("workshop/Lab 1/index.html"))

        let exported = try SessionHandoff.export(session, to: roots.inbox)

        let expected = (PhoneSession.files + ["workshop/Lab 1/index.html"]).sorted()
        let manifest = try JSONDecoder().decode(HandoffManifest.self, from: Data(contentsOf: ManifestFile.url(in: exported)))
        #expect(manifest.files.map(\.path) == expected)
        #expect(filePaths(in: exported) == (expected + [".thunderflow/handoff.json"]).sorted())
    }

    @Test("同一場再交一次：收件匣裡上次的那一份（沒交完的、或交完了的）整個換成這一次的，多出來的舊檔案不留下")
    func replacesAnEarlierCopy() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        let id = try session.loadMeta().id
        // 上次交到一半：錄音檔只複製了一部分，有一個這一次沒有的檔案，還有舊的 handoff.json
        let earlier = roots.inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        try writeFile("一部分", at: earlier.appendingPathComponent("recording.m4a"))
        try writeFile("舊的", at: earlier.appendingPathComponent("stale.txt"))
        try writeFile("{\"version\":1}", at: ManifestFile.url(in: earlier))
        let original = try folderSnapshot(session.url)

        let exported = try SessionHandoff.export(session, to: roots.inbox)

        #expect(exported.path == earlier.path)
        var copied = try folderSnapshot(exported)
        let manifestData = copied.removeValue(forKey: ".thunderflow/handoff.json")
        #expect(copied == original)
        let manifest = try JSONDecoder().decode(HandoffManifest.self, from: try #require(manifestData))
        #expect(manifest.files.map(\.path) == PhoneSession.files)

        // 交完了、手機上的那一份還沒刪（例如 App 剛好被關掉）就再交一次：結果一樣
        try SessionHandoff.export(session, to: roots.inbox)
        #expect(try folderSnapshot(exported).count == PhoneSession.files.count + 1)
        #expect(try JSONDecoder().decode(HandoffManifest.self, from: Data(contentsOf: ManifestFile.url(in: exported))).id == id)
    }

    @Test("複製到一半失敗時丟出錯誤，不寫 handoff.json，複製到一半的那一份也刪掉：Mac 不會收走半份")
    func failureLeavesNothingBehind() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        let id = try session.loadMeta().id
        // 逐字稿讀不到：依路徑排序它是最後一個，前面的檔案都已經複製過去了
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: session.transcriptURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: session.transcriptURL.path) }

        #expect(throws: (any Error).self) { try SessionHandoff.export(session, to: roots.inbox) }

        let folder = roots.inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        #expect(!fileExists(ManifestFile.url(in: folder)))
        #expect(!fileExists(folder))
        #expect(try roots.reader().scan().isEmpty)
    }

    @Test("還在錄音的場次（或上次沒有正常結束、還沒復原）不交出去：丟出 stillRecording，收件匣裡什麼都不放")
    func refusesARecordingSession() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone) { $0.state = .recording }

        #expect(throws: SessionHandoffError.stillRecording) { try SessionHandoff.export(session, to: roots.inbox) }

        #expect(filePaths(in: roots.inbox).isEmpty)
    }

    @Test("別人正在處理這一場（拿不到場次的鎖，例如結束處理還在做）：丟出 inProgress，收件匣裡什麼都不放")
    func refusesWhileLocked() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let session = try PhoneSession.make(in: roots.phone)
        let lock = try #require(try SessionLock.acquire(session))
        defer { lock.release() }

        #expect(throws: SessionHandoffError.inProgress) { try SessionHandoff.export(session, to: roots.inbox) }

        #expect(filePaths(in: roots.inbox).isEmpty)
    }

    @Test("交接的每一種錯誤：說明是給人看的中文，不出現程式裡的名稱")
    func errorsAreReadable() {
        let cases: [(SessionHandoffError, String)] = [
            (.stillRecording, "stillRecording"),
            (.inProgress, "inProgress"),
            (.sizeMismatch(path: "recording.m4a", expected: 30_672_310, found: 1_024), "sizeMismatch"),
            (.changedDuringCopy, "changedDuringCopy"),
            (.notEnoughSpace(needed: 300_000_000, available: 900_000_000, reserved: 1_000_000_000), "notEnoughSpace"),
            (.cannotRemove("沒有權限"), "cannotRemove"),
        ]
        for (error, name) in cases {
            let text = String(describing: error)
            #expect(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(name)：要有中文說明，實際是「\(text)」")
            #expect(!text.contains(name), "\(name)：不出現程式裡的名稱，實際是「\(text)」")
            #expect(error.localizedDescription == text, "\(name)：localizedDescription 是「\(error.localizedDescription)」")
        }
    }
}
