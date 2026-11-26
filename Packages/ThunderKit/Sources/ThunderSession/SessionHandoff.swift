import Foundation
import ThunderCore

/// `handoff.json`：手機交給 Mac 的清單（DESIGN.md 5.10 節，D36）。只在收件匣與收進來的場次的 `.thunderflow/` 裡。
///
///     {"files":[{"path":"recording.m4a","size":30672310},…],"from":"iPhone","id":"6F1C…","version":1}
///
/// `files` 列出場次資料夾裡除了 `handoff.json` 自己以外的每個檔案（相對路徑、位元組數），隱藏檔不列。
/// Mac 看到這份清單、而且列出的每個檔案都在、大小一樣，才算收到（iCloud 一個檔案一個檔案同步，順序不一定）。
public struct HandoffManifest: Sendable, Equatable, Codable {
    /// 這個檔案自己的格式版本（和 `session.json` 的 `schemaVersion` 無關）。
    public static let currentVersion = 1
    /// 在場次資料夾裡的位置。
    public static let relativePath = ".thunderflow/handoff.json"

    public struct File: Sendable, Equatable, Codable {
        /// 相對於場次資料夾的路徑，以「/」分隔，例如 `.thunderflow/session.json`。
        public var path: String
        /// 位元組數。
        public var size: Int64

        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public var version: Int
    /// 場次的 id（`session.json` 的 `id`），也是收件匣裡資料夾的名稱。
    public var id: UUID
    /// 從哪裡來的，例如「iPhone」。
    public var from: String
    public var files: [File]

    public init(id: UUID, from: String, files: [File]) {
        version = Self.currentVersion
        self.id = id
        self.from = from
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, from, files
    }

    /// 先看 `version`：不是這一版認識的格式就丟出 `SessionHandoffError.unsupportedVersion`，不再往下讀
    /// （其他欄位的意義可能已經不同）。`from` 缺少時是空字串。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw SessionHandoffError.unsupportedVersion(found: version) }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            from: try container.decodeIfPresent(String.self, forKey: .from) ?? "",
            files: try container.decode([File].self, forKey: .files))
    }

    static func decode(_ data: Data) throws -> HandoffManifest {
        try JSONDecoder().decode(HandoffManifest.self, from: data)
    }

    /// 原子寫進 `folder` 的 `.thunderflow/handoff.json`：一行 JSON，欄位依字母排序，斜線不跳脫。
    func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
        let url = folder.appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionDirectory(url: folder).writeText(json, to: url)
    }
}

public enum SessionHandoffError: Error, Equatable {
    /// 這一場還在錄音，或上次沒有正常結束、還沒復原：不能交出去。
    case stillRecording
    /// 別人正在處理這一場（錄音或結束處理），這一次什麼都沒有做。
    case inProgress
    /// 複製出來的檔案和應該有的大小不一樣（複製途中檔案又變了）。
    case sizeMismatch(path: String, expected: Int64, found: Int64)
    /// 收件匣裡的這一份在複製途中又換了一次（手機又交了一次）。
    case changedDuringCopy
    /// 磁碟空間不夠：收進來要 `needed` 個位元組，收完之後至少要留下 `reserved` 個，現在只有 `available` 個。
    case notEnoughSpace(needed: Int64, available: Int64, reserved: Int64)
    /// 這一場已經收進來了（或早就收過），但收件匣裡的那一份移不走（附上原因）。
    case cannotRemove(String)
    /// `handoff.json` 的格式版本不是這一版認識的。
    case unsupportedVersion(found: Int)
}

extension SessionHandoffError: CustomStringConvertible, LocalizedError {
    /// 給人看的說明（放進句子裡，句尾不加句號）。
    public var description: String {
        switch self {
        case .stillRecording: "這一場還在錄音，或上次沒有正常結束、還沒復原"
        case .inProgress: "這一場正在處理中"
        case .sizeMismatch(let path, let expected, let found):
            "「\(path)」複製出來是 \(found) 個位元組，應該是 \(expected) 個（複製途中檔案又變了）"
        case .changedDuringCopy: "收件匣裡的這一份在複製途中又換了一次"
        case .notEnoughSpace(let needed, let available, let reserved):
            "磁碟空間不夠：收進來要 \(Self.megabytes(needed))，收完之後要留下 \(Self.megabytes(reserved)) 給錄音用，"
                + "現在只剩 \(Self.megabytes(available))"
        case .cannotRemove(let reason): "這一場已經收進來了，但收件匣裡的那一份移不走（\(reason)），可以自己把它移到垃圾桶"
        case .unsupportedVersion(let found) where found > HandoffManifest.currentVersion:
            "handoff.json 是比較新版的 ThunderFlow 寫的（格式第 \(found) 版，這一版只讀得懂第 \(HandoffManifest.currentVersion) 版），"
                + "請更新 ThunderFlow"
        case .unsupportedVersion(let found): "handoff.json 的格式（第 \(found) 版）不認識"
        }
    }

    public var errorDescription: String? { description }

    private static func megabytes(_ bytes: Int64) -> String {
        "\(max(0, bytes) / 1_000_000) MB"
    }
}

/// 手機交給 Mac（DESIGN.md 5.10 節，D36）：手機把場次複製到收件匣，Mac 收走之後接著做結束處理。
public enum SessionHandoff {
    /// iPhone 版自己的 iCloud 空間（D37）：收件匣放在這裡，使用者不用選資料夾。和 `iOS/ThunderFlowPhone.entitlements` 一致。
    public static let containerIdentifier = "iCloud.io.github.ruan330.thunderflow"

    /// 收件匣在 container 裡的位置：`Inbox/`。不放在 `Documents/` 裡，也不公開 container：使用者在 iCloud 雲碟裡看不到，
    /// 不會誤動。iPhone 用 `FileManager.url(forUbiquityContainerIdentifier:)` 拿到 container。
    public static func inbox(inContainer container: URL) -> URL {
        container.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// 放 Library 的位置（D38）：container 的 `Documents/`。
    public static func library(inContainer container: URL) -> URL {
        container
    }

    /// 同一個 Library 在 Mac 上的位置。
    public static func macLibrary(home: URL) -> URL {
        home
    }

    /// 同一個收件匣在 Mac 上的位置：iCloud 把每個 container 放在 `~/Library/Mobile Documents/<識別碼，「.」換成「~」>/`。
    /// Mac 版是 ad-hoc 簽章、沒有 iCloud 的 entitlement，直接用路徑讀寫（iCloud 照樣同步）。
    public static func macInbox(home: URL) -> URL {
        let folder = containerIdentifier.replacingOccurrences(of: ".", with: "~")
        return inbox(
            inContainer: home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true))
    }

    /// 把 `directory` 複製到 `<inbox>/<場次 id>/`，**最後**才寫 `.thunderflow/handoff.json`。回傳收件匣裡的那一份的位置。
    ///
    /// - 通常在結束處理做到 `audio`（`FinalizationOptions.lastStep`）之後呼叫：狀態是 `finalizing`，
    ///   Mac 收到之後從還沒做的步驟（發布、摘要）接著做。
    /// - 複製場次資料夾裡的每個一般檔案（包括子資料夾裡的）。名稱以「.」開頭的（`.DS_Store`、iCloud 的暫存檔、
    ///   寫到一半的暫存檔）不複製也不列，`.thunderflow/` 例外；已經有的 `handoff.json` 不複製，由這一次重新寫。
    /// - `handoff.json` 原子寫入，寫好之前 Mac 不會收。中途失敗時丟出錯誤，並刪掉複製到一半的那一份
    ///   （刪不掉的也沒有 `handoff.json`，Mac 不會收；再交一次就會取代它）。
    /// - 收件匣裡已經有同一個 id 的資料夾（上次沒交完，或交完了、手機上的那一份還沒刪）時，先整個刪掉再複製。
    /// - 狀態還是 `recording` 的場次丟出 `stillRecording`；別人正持有場次的鎖（錄音中、結束處理中）時丟出 `inProgress`。
    ///   兩種情況都什麼都不動。複製期間持有場次的鎖。
    /// - 寫收件匣用 `NSFileCoordinator` 協調：iCloud 雲碟裡、用系統的資料夾選擇器拿到的資料夾要這樣寫，iCloud 才會知道。
    ///   會等磁碟與 iCloud，不要在主執行緒上呼叫。收件匣的存取權限（security-scoped URL）由呼叫端負責。
    /// - 手機上的那一份不動：交好之後由呼叫端刪掉（DESIGN.md 5.10 節）。
    @discardableResult
    public static func export(_ directory: SessionDirectory, to inbox: URL, from device: String = "iPhone") throws -> URL {
        guard let lock = try SessionLock.acquire(directory) else {
            let state = try? directory.loadMeta().state
            throw state == .recording ? SessionHandoffError.stillRecording : SessionHandoffError.inProgress
        }
        defer { lock.release() }
        let meta = try directory.loadMeta()
        guard meta.state != .recording else { throw SessionHandoffError.stillRecording }
        let files = try HandoffFiles.list(in: directory.url)
        let destination = inbox.appendingPathComponent(meta.id.uuidString, isDirectory: true)
        try HandoffFiles.coordinatedWrite(at: destination) { destination in
            let fileManager = FileManager.default
            do {
                try HandoffFiles.removeEarlierCopy(at: destination)
                // 收件匣本身不存在（被搬走、刪掉）時失敗，不在原處另建一個
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                for file in files {
                    let target = destination.appendingPathComponent(file.path)
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: directory.url.appendingPathComponent(file.path), to: target)
                    let copied = HandoffFiles.item(at: target)?.size ?? -1
                    guard copied == file.size else {
                        throw SessionHandoffError.sizeMismatch(path: file.path, expected: file.size, found: copied)
                    }
                }
                // 最後才寫：寫好之前 Mac 不會收
                try HandoffManifest(id: meta.id, from: device, files: files).write(in: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        return destination
    }
}

/// 交接用到的檔案操作。
enum HandoffFiles {
    /// 場次資料夾裡要交出去的檔案，依路徑排序：一般的檔案（不跟著符號連結走），包括子資料夾裡的；
    /// 名稱以「.」開頭的不算（`.thunderflow/` 例外），`handoff.json` 自己也不算。
    static func list(in root: URL) throws -> [HandoffManifest.File] {
        var files: [HandoffManifest.File] = []
        func walk(_ relative: String) throws {
            let folder = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                guard !name.hasPrefix(".") || (relative.isEmpty && name == ".thunderflow") else { continue }
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                guard path != HandoffManifest.relativePath, let item = item(at: folder.appendingPathComponent(name)) else {
                    continue
                }
                if item.type == .typeDirectory {
                    try walk(path)
                } else if item.type == .typeRegular {
                    files.append(HandoffManifest.File(path: path, size: item.size))
                }
            }
        }
        try walk("")
        return files.sorted { $0.path < $1.path }
    }

    /// 這個位置上的東西的種類與大小（不跟著符號連結走）；不存在時是 nil。只看檔案系統的資料，不讀內容：
    /// iCloud 雲碟裡還沒下載的檔案也看得到大小，不會觸發下載。
    static func item(at url: URL) -> (type: FileAttributeType, size: Int64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else { return nil }
        return (type, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// 刪掉收件匣裡同一場上次的那一份。先拿掉舊的 `handoff.json`：刪除途中 Mac 不會把新舊混在一起的資料夾當成收到。
    static func removeEarlierCopy(at destination: URL) throws {
        let manifest = destination.appendingPathComponent(HandoffManifest.relativePath)
        if item(at: manifest) != nil { try FileManager.default.removeItem(at: manifest) }
        if item(at: destination) != nil { try FileManager.default.removeItem(at: destination) }
    }

    /// 以 `NSFileCoordinator` 協調的寫入：iCloud 雲碟（以及其他檔案提供者）因此知道這個位置的東西換了。
    static func coordinatedWrite(at url: URL, _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var workError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            do { try work(url) } catch { workError = error }
        }
        if let workError { throw workError }
        if let coordinationError { throw coordinationError }
    }
}
