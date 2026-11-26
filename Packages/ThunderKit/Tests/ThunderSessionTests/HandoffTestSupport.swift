import Foundation
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 手機上做到 `audio` 的場次（DESIGN.md 5.10 節）：不經過真的結束處理，直接寫出那時會有的檔案，
/// 測試又快、內容又確定。`recording.m4a` 不是真的錄音（這些測試不播放、不合併）。
enum PhoneSession {
    static let source = "iPhone 麥克風"
    static let recordingBytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    /// 在 `root` 底下建立一個場次（以場次 id 命名）：`session.json`（finalizing，前三步做完）、日誌、段落、逐字稿與錄音檔。
    static func make(in root: URL, configure: (inout SessionMeta) -> Void = { _ in }) throws -> SessionDirectory {
        let directory = try Finished.makeSession(in: root, audio: []) { meta in
            meta.source = source
            meta.durationSeconds = 45
            meta.completedSteps = ["blocks", "transcript", "audio"]
            configure(&meta)
        }
        // 合併錄音之後就沒有 audio/
        try FileManager.default.removeItem(at: directory.audioDirectoryURL)
        try TranscriptBlocks.write(Finished.blocks, to: directory.blocksURL)
        try directory.writeText(
            TranscriptMarkdown.render(meta: try directory.loadMeta(), blocks: Finished.blocks), to: directory.transcriptURL)
        try recordingBytes.write(to: directory.recordingURL)
        return directory
    }

    /// 這樣建立的場次交出去時，`handoff.json` 應該列出的檔案（依路徑排序）。
    static let files = [
        ".thunderflow/blocks.jsonl", ".thunderflow/journal.jsonl", ".thunderflow/session.json", "recording.m4a",
        "transcript.md",
    ]
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// 直接讀寫收件匣裡那一份的 `handoff.json`（JSON），測試才做得出各種有問題的內容。
enum ManifestFile {
    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(".thunderflow/handoff.json")
    }

    static func read(in folder: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url(in: folder))) as? [String: Any] else {
            throw FixtureError(description: "handoff.json 不是 JSON 物件")
        }
        return object
    }

    static func write(_ object: [String: Any], in folder: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url(in: folder))
    }

    /// 改一下 `handoff.json` 的內容。
    static func edit(in folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        var object = try read(in: folder)
        change(&object)
        try write(object, in: folder)
    }

    /// 依檔案現在的大小重寫 `files` 裡的 `size`：場次的檔案被改過之後，讓清單和檔案對得上。
    static func refreshSizes(in folder: URL) throws {
        try edit(in: folder) { object in
            let files = object["files"] as? [[String: Any]] ?? []
            object["files"] = files.map { entry -> [String: Any] in
                var entry = entry
                let path = folder.appendingPathComponent(entry["path"] as? String ?? "").path
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                entry["size"] = size?.int64Value ?? 0
                return entry
            }
        }
    }
}

/// 手機、收件匣、Mac 的工作目錄與 Library，都在這個測試自己的暫存資料夾裡。
struct HandoffRoots {
    let tmp: TemporaryDirectory
    var phone: URL { tmp.url.appendingPathComponent("Phone", isDirectory: true) }
    var inbox: URL { tmp.url.appendingPathComponent("Inbox", isDirectory: true) }
    var working: URL { tmp.url.appendingPathComponent("Working", isDirectory: true) }
    var library: URL { tmp.url.appendingPathComponent("Library", isDirectory: true) }

    init() throws {
        tmp = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    /// Mac 的收件匣。收好之後直接刪掉收件匣裡的那一份（不經過垃圾桶），並記在 `removed`。
    func reader(removed: LockedValue<[URL]>? = nil) -> SessionInbox {
        SessionInbox(inbox: inbox, workingRoot: working, libraryRoot: library) { url in
            removed?.withValue { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 手機上錄好一場、交到收件匣，再刪掉手機上的那一份。回傳收件匣裡的那一份與場次的 id。
    @discardableResult
    func handOff(configure: (inout SessionMeta) -> Void = { _ in }) throws -> (folder: URL, id: UUID) {
        let session = try PhoneSession.make(in: phone, configure: configure)
        let id = try session.loadMeta().id
        let folder = try SessionHandoff.export(session, to: inbox)
        try FileManager.default.removeItem(at: session.url)
        return (folder, id)
    }

    /// 工作目錄裡的項目名稱（包括隱藏的），依名稱排序；工作目錄不存在時是空的。
    var workingItems: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: working.path)) ?? []).sorted()
    }
}
