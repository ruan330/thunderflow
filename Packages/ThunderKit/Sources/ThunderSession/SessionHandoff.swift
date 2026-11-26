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
        }
    }

    public var errorDescription: String? { description }

    private static func megabytes(_ bytes: Int64) -> String {
        "\(max(0, bytes) / 1_000_000) MB"
    }
}

/// 手機交給 Mac（DESIGN.md 5.10 節，D36）：手機把場次複製到收件匣，Mac 收走之後接著做結束處理。
public enum SessionHandoff {
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
        // 空殼：還沒有實作
        inbox.appendingPathComponent((try? directory.loadMeta().id.uuidString) ?? "", isDirectory: true)
    }
}
