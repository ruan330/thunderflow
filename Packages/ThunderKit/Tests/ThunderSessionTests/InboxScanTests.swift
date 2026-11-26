import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// `handoff.json` 的各種問題。
enum ManifestDefect: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case notJSON = "不是 JSON"
    case newerVersion = "比較新的格式版本"
    case unknownVersion = "不認識的格式版本 0"
    case otherID = "id 和資料夾名稱對不上"
    case parentPath = "路徑有 .."
    case absolutePath = "絕對路徑"
    case detour = "路徑繞出場次資料夾再繞回來"
    case listsItself = "列出 handoff.json 自己"
    case noSessionFile = "沒有列出 session.json"
    case notAFile = "列出的是資料夾"

    var testDescription: String { rawValue }

    /// 說明裡一定要有的字。
    var keyword: String {
        switch self {
        case .notJSON, .listsItself: "handoff.json"
        case .newerVersion: "請更新 ThunderFlow"
        case .unknownVersion: "第 0 版"
        case .otherID: "資料夾名稱"
        case .parentPath, .absolutePath, .detour: "場次資料夾"
        case .noSessionFile: "session.json"
        case .notAFile: "不是一般的檔案"
        }
    }

    /// 把收件匣裡那一份的 `handoff.json` 弄成有這個問題（場次的檔案都還在、大小也對）。
    func apply(to folder: URL) throws {
        func addFile(_ path: String, size: Int) throws {
            try ManifestFile.edit(in: folder) { object in
                object["files"] = (object["files"] as? [[String: Any]] ?? []) + [["path": path, "size": size]]
            }
        }
        switch self {
        case .notJSON:
            try writeFile("這不是 JSON", at: ManifestFile.url(in: folder))
        case .newerVersion:
            try ManifestFile.edit(in: folder) { $0["version"] = 2 }
        case .unknownVersion:
            try ManifestFile.edit(in: folder) { $0["version"] = 0 }
        case .otherID:
            try ManifestFile.edit(in: folder) { $0["id"] = UUID().uuidString }
        case .parentPath:
            // 路徑指到的檔案真的存在：問題是路徑本身，不是檔案還沒到
            try writeFile("秘密", at: folder.deletingLastPathComponent().appendingPathComponent("secret.txt"))
            try addFile("../secret.txt", size: 6)
        case .absolutePath:
            let size = try FileManager.default.attributesOfItem(atPath: "/etc/hosts")[.size] as? NSNumber
            try addFile("/etc/hosts", size: size?.intValue ?? 0)
        case .detour:
            try writeFile("秘密", at: folder.deletingLastPathComponent().appendingPathComponent("secret.txt"))
            try addFile(".thunderflow/../../secret.txt", size: 6)
        case .listsItself:
            let size = try Data(contentsOf: ManifestFile.url(in: folder)).count
            try addFile(".thunderflow/handoff.json", size: size)
        case .noSessionFile:
            try ManifestFile.edit(in: folder) { object in
                object["files"] = (object["files"] as? [[String: Any]] ?? []).filter {
                    $0["path"] as? String != ".thunderflow/session.json"
                }
            }
        case .notAFile:
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("workshop", isDirectory: true), withIntermediateDirectories: true)
            try addFile("workshop", size: 0)
        }
    }
}

/// `session.json` 的各種問題（`handoff.json` 本身沒問題，列出的大小也對）。
enum SessionDefect: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case newerSchema = "比較新版的 ThunderFlow 寫的"
    case otherID = "id 和 handoff.json 不一樣"
    case stillRecording = "手機上還沒結束錄音"
    case notJSON = "讀不懂"

    var testDescription: String { rawValue }

    /// 說明裡一定要有的字。
    var keyword: String {
        switch self {
        case .newerSchema: "請更新 ThunderFlow"
        case .otherID: "id"
        case .stillRecording: "錄音"
        case .notJSON: "session.json"
        }
    }

    func apply(to folder: URL) throws {
        let directory = SessionDirectory(url: folder)
        switch self {
        case .newerSchema:
            var object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: directory.metaURL)) as? [String: Any] ?? [:]
            object["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: directory.metaURL)
        case .otherID:
            var meta = try directory.loadMeta()
            meta.id = UUID()
            try directory.saveMeta(meta)
        case .stillRecording:
            var meta = try directory.loadMeta()
            meta.state = .recording
            try directory.saveMeta(meta)
        case .notJSON:
            try writeFile("這不是 JSON", at: directory.metaURL)
        }
        try ManifestFile.refreshSizes(in: folder)
    }
}

/// Mac 看收件匣（DESIGN.md 5.10 節，D36）：`handoff.json` 讀得到、列出的每個檔案都在而且大小一樣，才算收到。
@Suite("Mac 的收件匣：handoff.json 與列出的檔案都到齊才收（D36）", .timeLimit(.minutes(1)))
struct InboxScanTests {
    @Test("handoff.json 讀得到、列出的每個檔案都在而且大小一樣：可以收")
    func readyWhenEverythingArrived() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, id) = try roots.handOff()

        let entries = try roots.reader().scan()

        #expect(entries.map(\.folder.path) == [folder.path])
        guard case .ready(let manifest) = entries.first?.status else {
            Issue.record("應該可以收，實際是 \(String(describing: entries.first?.status))")
            return
        }
        #expect(manifest.id == id)
        #expect(manifest.from == "iPhone")
        #expect(manifest.files.map(\.path) == PhoneSession.files)
    }

    @Test("handoff.json 還沒到（手機還在複製，或 iCloud 還沒同步過來）：還在等，不收也不算有問題")
    func waitsForTheManifest() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        try FileManager.default.removeItem(at: ManifestFile.url(in: folder))

        #expect(try roots.reader().scan() == [InboxEntry(folder: folder, status: .waiting)])
        #expect(roots.reader().collect() == InboxReport(waiting: [folder]))
        #expect(fileExists(folder))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("列出的檔案還沒到、或大小還不一樣（iCloud 一個檔案一個檔案同步）：還在等", arguments: ["還沒到", "還不完整"])
    func waitsForEveryListedFile(_ situation: String) throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        let recording = folder.appendingPathComponent("recording.m4a")
        if situation == "還沒到" {
            try FileManager.default.removeItem(at: recording)
        } else {
            try PhoneSession.recordingBytes.prefix(1_000).write(to: recording)
        }

        #expect(try roots.reader().scan() == [InboxEntry(folder: folder, status: .waiting)])
        #expect(roots.reader().collect() == InboxReport(waiting: [folder]))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("handoff.json 有問題（讀不懂、不認識的版本、id 對不上、路徑跑出場次資料夾…）：不收，留在收件匣裡並說明原因", arguments: ManifestDefect.allCases)
    func rejectsBadManifests(_ defect: ManifestDefect) throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        try defect.apply(to: folder)

        let entries = try roots.reader().scan()

        #expect(entries.map(\.folder.path) == [folder.path])
        guard case .rejected(let reason) = entries.first?.status else {
            Issue.record("應該不收，實際是 \(String(describing: entries.first?.status))")
            return
        }
        #expect(reason.contains(defect.keyword), "實際是「\(reason)」")
        let report = roots.reader().collect()
        #expect(report == InboxReport(problems: [InboxReport.Problem(folder: folder, reason: reason)]))
        #expect(fileExists(ManifestFile.url(in: folder)))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("session.json 有問題（比較新版的 ThunderFlow 寫的、id 和 handoff.json 不一樣、手機上還在錄音、讀不懂）：不收，說明原因", arguments: SessionDefect.allCases)
    func rejectsBadSessions(_ defect: SessionDefect) throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        try defect.apply(to: folder)

        let entries = try roots.reader().scan()

        guard case .rejected(let reason) = entries.first?.status else {
            Issue.record("應該不收，實際是 \(String(describing: entries.first?.status))")
            return
        }
        #expect(reason.contains(defect.keyword), "實際是「\(reason)」")
        #expect(roots.reader().collect().problems == [InboxReport.Problem(folder: folder, reason: reason)])
        #expect(fileExists(folder))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("收件匣裡名稱以「.」開頭的項目與不是資料夾的東西都不理會")
    func ignoresHiddenItemsAndFiles() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        try writeFile("雜檔", at: roots.inbox.appendingPathComponent(".DS_Store"))
        try writeFile("筆記", at: roots.inbox.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: roots.inbox.appendingPathComponent(".Trash/old", isDirectory: true), withIntermediateDirectories: true)

        #expect(try roots.reader().scan().map(\.folder.path) == [folder.path])
    }

    @Test("收件匣不存在（被搬走、改名或刪掉）：scan 丟出錯誤；collect 說明找不到收件匣，什麼都不收")
    func missingInbox() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        try FileManager.default.removeItem(at: roots.inbox)

        #expect(throws: (any Error).self) { try roots.reader().scan() }
        let report = roots.reader().collect()
        #expect(report.problems.map(\.folder.path) == [roots.inbox.path])
        #expect(report.problems.first?.reason.contains("收件匣") == true)
        #expect(report.received.isEmpty)
        #expect(roots.workingItems.isEmpty)
    }

    @Test("收件匣不能是 Library 本身或 Library 裡面的資料夾（經過符號連結也一樣）；旁邊的、上一層的資料夾可以")
    func inboxMustNotBeInsideTheLibrary() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let inside = roots.library.appendingPathComponent("收件匣", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let link = roots.tmp.url.appendingPathComponent("捷徑", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: roots.library)

        #expect(SessionInbox.problem(inbox: roots.library, library: roots.library) != nil)
        #expect(SessionInbox.problem(inbox: URL(fileURLWithPath: roots.library.path + "/"), library: roots.library) != nil)
        #expect(SessionInbox.problem(inbox: inside, library: roots.library) != nil)
        #expect(SessionInbox.problem(inbox: link.appendingPathComponent("收件匣"), library: roots.library) != nil)
        #expect(SessionInbox.problem(inbox: roots.inbox, library: roots.library) == nil)
        #expect(SessionInbox.problem(inbox: roots.tmp.url, library: roots.library) == nil)
        // 名稱的開頭和 Library 一樣、但在旁邊的資料夾不算在裡面
        let sibling = roots.tmp.url.appendingPathComponent("Library 收件匣", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(SessionInbox.problem(inbox: sibling, library: roots.library) == nil)
    }

    @Test("收件匣在 Library 裡面時（例如之後才改了 Library）：不看也不收，說明要重新選擇")
    func refusesAnInboxInsideTheLibrary() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        try roots.handOff()
        // Library 改成收件匣的上一層
        let reader = SessionInbox(inbox: roots.inbox, workingRoot: roots.working, libraryRoot: roots.tmp.url) { url in
            try FileManager.default.removeItem(at: url)
        }

        let report = reader.collect()

        #expect(report.received.isEmpty)
        #expect(report.problems.map(\.folder.path) == [roots.inbox.path])
        #expect(roots.workingItems.isEmpty)
        #expect(filePaths(in: roots.inbox).count == PhoneSession.files.count + 1)
    }
}
