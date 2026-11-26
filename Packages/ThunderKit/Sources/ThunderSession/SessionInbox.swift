import Foundation
import ThunderCore

/// 收件匣裡的一個場次資料夾，和它現在的狀況。
public struct InboxEntry: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// `handoff.json` 讀得到、列出的每個檔案都在而且大小一樣：可以收。
        case ready(HandoffManifest)
        /// 還沒到齊：`handoff.json` 還沒到，或列出的檔案還沒到齊、大小還不一樣、還讀不到（例如還在從 iCloud 下載）。
        /// 下次再看。
        case waiting
        /// 不收：留在收件匣裡（每次都再看一次），附上給人看的原因（句尾不加句號），設定頁顯示。
        case rejected(String)
    }

    public var folder: URL
    public var status: Status

    public init(folder: URL, status: Status) {
        self.folder = folder
        self.status = status
    }
}

/// 收進一份的結果。
public enum InboxReceipt: Sendable, Equatable {
    /// 收進工作目錄了：接著做結束處理。
    case received(SessionDirectory)
    /// 工作目錄或 Library 裡已經有這一場：沒有再複製，只把收件匣裡的那一份移走。
    case alreadyReceived
    /// 另一個 ThunderFlow 正在收這一份：這一次什麼都沒有做。
    case busy
}

/// 看一次收件匣、收進準備好的場次之後的結果。
public struct InboxReport: Sendable, Equatable {
    /// 收進工作目錄的一場。
    public struct Received: Sendable, Equatable {
        /// 場次的 id。
        public var id: UUID
        /// 收進來之後在工作目錄裡的位置。
        public var directory: SessionDirectory
        /// 從哪裡來的（`handoff.json` 的 `from`），例如「iPhone」。
        public var from: String

        public init(id: UUID, directory: SessionDirectory, from: String) {
            self.id = id
            self.directory = directory
            self.from = from
        }
    }

    /// 沒有收進來的資料夾與原因（給人看，句尾不加句號）。收件匣本身有問題時，`folder` 是收件匣。
    public struct Problem: Sendable, Equatable {
        public var folder: URL
        public var reason: String

        public init(folder: URL, reason: String) {
            self.folder = folder
            self.reason = reason
        }
    }

    /// 這一次收進工作目錄的場次：接著做結束處理。
    public var received: [Received]
    /// 已經收過（工作目錄或 Library 裡已經有同一個 id）、這一次只把收件匣裡的那一份移走的場次。
    public var alreadyReceived: [UUID]
    /// 還沒到齊、下次再看的資料夾。
    public var waiting: [URL]
    /// 沒有收進來的資料夾與原因：留在收件匣裡，下次再看一次。
    public var problems: [Problem]

    public init(received: [Received] = [], alreadyReceived: [UUID] = [], waiting: [URL] = [], problems: [Problem] = []) {
        self.received = received
        self.alreadyReceived = alreadyReceived
        self.waiting = waiting
        self.problems = problems
    }

    /// 收進新的場次時給人看的一句話，例如「收到 iPhone 錄的 2 場，正在處理。」；沒有收進任何一場時是 nil。
    public var announcement: String? {
        // 空殼：還沒有實作
        nil
    }
}

/// Mac 的收件匣（DESIGN.md 5.10 節，D36）：手機把錄好的場次放進 iCloud 雲碟裡的這個資料夾，Mac 收進工作目錄，
/// 接著走一般的結束處理（搬進 Library、摘要與自動命名）。
///
/// 會讀 iCloud 雲碟裡的檔案（可能要等它下載）、複製整場錄音：都不要在主執行緒上做。
public struct SessionInbox: Sendable {
    /// 收件匣。
    public var inbox: URL
    /// 工作目錄：收進來的場次放在這裡（和錄完、還沒搬進 Library 的場次一樣）。
    public var workingRoot: URL
    /// Library：同一個 id 已經在這裡就不再收。
    public var libraryRoot: URL
    /// 收進來之後，工作目錄所在的磁碟至少要留下的空間（位元組）：錄音中的那一場要用。不夠時不收。
    public var reservedSpace: Int64
    /// 收好之後怎麼移走收件匣裡的那一份。預設移到垃圾桶（`moveToTrash`）。
    public var remove: @Sendable (URL) throws -> Void

    public init(
        inbox: URL, workingRoot: URL, libraryRoot: URL,
        remove: @escaping @Sendable (URL) throws -> Void = SessionInbox.moveToTrash
    ) {
        self.inbox = inbox
        self.workingRoot = workingRoot
        self.libraryRoot = libraryRoot
        reservedSpace = 1_000_000_000
        self.remove = remove
    }

    /// 移到垃圾桶（DESIGN.md 5.9 節：刪除一律移到垃圾桶）。iCloud 雲碟裡的刪除會同步到手機。
    public static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// 這個資料夾能不能當收件匣：不能是 Library 本身，也不能在 Library 裡面。
    /// 可以時回傳 nil，不行時回傳給人看的原因（句尾不加句號）。
    public static func problem(inbox: URL, library: URL) -> String? {
        // 空殼：還沒有實作
        nil
    }

    /// 看一次收件匣：每個場次資料夾（名稱以「.」開頭的、不是資料夾的東西不算）現在的狀況，依名稱排序。不複製、不移動任何東西。
    ///
    /// 可以收（`ready`）的條件：`.thunderflow/handoff.json` 讀得懂、`version` 是 1、`id` 和資料夾名稱一樣、
    /// 每個路徑都在場次資料夾裡面（沒有 `..`、不是絕對路徑）、有列出 `.thunderflow/session.json`，
    /// 列出的每個檔案都在、是一般的檔案、大小一樣；最後 `session.json` 讀得懂、`id` 和 `handoff.json` 一樣、
    /// 狀態不是 `recording`。檔案還沒到齊或還讀不到是 `waiting`，其他不符合的是 `rejected`。
    /// 收件匣讀不到（例如不存在）時丟出錯誤。
    public func scan() throws -> [InboxEntry] {
        // 空殼：還沒有實作
        []
    }

    /// 收進一份（`scan` 回報可以收的資料夾與它的 `handoff.json`）。
    ///
    /// - 工作目錄或 Library 裡已經有同一個 id 的場次（看 `session.json` 的 `id`）：不複製，只把收件匣裡的那一份移走。
    /// - 否則先複製到工作目錄裡的暫存位置（`.receiving/<場次 id>/`，多一層，中途中斷也不會被當成場次），
    ///   再核對一次大小，然後改名成 `<工作目錄>/<場次 id>/`（名稱被占用時加序號），最後把收件匣裡的那一份移走。
    ///   只複製 `handoff.json` 列出的檔案，加上 `handoff.json` 本身（留在 `.thunderflow/` 裡，說明這一場是從手機來的）。
    /// - 移走失敗不影響已經收進來的場次：下次看到時當成已經收過，再移一次。
    /// - 複製失敗、大小對不上、磁碟空間不夠時丟出錯誤：暫存的複製刪掉，收件匣裡的那一份留著，下次再試。
    /// - 收的期間鎖住收件匣裡的那一份：另一個 ThunderFlow 正在收它時回傳 `busy`，什麼都不做。
    public func receive(_ folder: URL, manifest: HandoffManifest) throws -> InboxReceipt {
        // 空殼：還沒有實作
        .busy
    }

    /// 看一次收件匣，收進每一份可以收的（`scan`、`receive`）。不會丟出錯誤：收件匣本身有問題（不存在、讀不到、
    /// 在 Library 裡面）與每一份沒收進來的原因都記在 `problems`。
    public func collect() -> InboxReport {
        // 空殼：還沒有實作
        InboxReport()
    }
}
