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
        guard !received.isEmpty else { return nil }
        var sources: [String] = []
        for item in received where !item.from.isEmpty && !sources.contains(item.from) { sources.append(item.from) }
        let from = sources.isEmpty ? "收到手機錄的" : "收到 \(sources.joined(separator: "、")) 錄的"
        return "\(from) \(received.count) 場，正在處理。"
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

    /// 這個資料夾能不能當收件匣：不能是 Library 本身，也不能在 Library 裡面（兩邊都解析成實際的路徑再比較，
    /// 所以經過符號連結也認得出來）。可以時回傳 nil，不行時回傳給人看的原因（句尾不加句號）。
    public static func problem(inbox: URL, library: URL) -> String? {
        let inboxPath = realPath(inbox)
        let libraryPath = realPath(library)
        let prefix = libraryPath.hasSuffix("/") ? libraryPath : libraryPath + "/"
        guard inboxPath == libraryPath || inboxPath.hasPrefix(prefix) else { return nil }
        return "收件匣不能是儲存錄音的資料夾（Library）本身，也不能在它裡面"
    }

    /// 實際的路徑（解析符號連結，例如 /tmp → /private/tmp）；不存在時是整理過的路徑。
    private static func realPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 看一次收件匣：每個場次資料夾（名稱以「.」開頭的、不是資料夾的東西不算）現在的狀況，依名稱排序。不複製、不移動任何東西。
    ///
    /// 可以收（`ready`）的條件：`.thunderflow/handoff.json` 讀得懂、`version` 是 1、`id` 和資料夾名稱一樣、
    /// 每個路徑都在場次資料夾裡面（沒有 `..`、不是絕對路徑）、有列出 `.thunderflow/session.json`，
    /// 列出的每個檔案都在、是一般的檔案、大小一樣；最後 `session.json` 讀得懂、`id` 和 `handoff.json` 一樣、
    /// 狀態不是 `recording`。檔案還沒到齊或還讀不到是 `waiting`，其他不符合的是 `rejected`。
    /// 收件匣讀不到（例如不存在）時丟出錯誤。
    public func scan() throws -> [InboxEntry] {
        var entries: [InboxEntry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted() where !name.hasPrefix(".") {
            let folder = inbox.appendingPathComponent(name, isDirectory: true)
            guard HandoffFiles.item(at: folder)?.type == .typeDirectory else { continue }
            entries.append(InboxEntry(folder: folder, status: Self.status(of: folder)))
        }
        return entries
    }

    /// `session.json` 在場次資料夾裡的位置（`handoff.json` 一定要列出它）。
    private static let metaPath = ".thunderflow/session.json"

    /// 一個場次資料夾現在的狀況（`scan` 的說明）。只讀 `handoff.json` 與 `session.json` 兩個小檔，
    /// 其他檔案只看檔案系統的資料（大小），不讀內容：還沒從 iCloud 下載的大檔不會因此被下載。
    private static func status(of folder: URL) -> InboxEntry.Status {
        // 還沒到，或還讀不到（例如還在從 iCloud 下載）：下次再看
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(HandoffManifest.relativePath)) else {
            return .waiting
        }
        let manifest: HandoffManifest
        do {
            manifest = try HandoffManifest.decode(data)
        } catch let error as SessionHandoffError {
            return .rejected(error.description)
        } catch {
            return .rejected("handoff.json 讀不懂")
        }
        if let problem = problem(with: manifest, in: folder) { return .rejected(problem) }
        for file in manifest.files {
            guard let item = HandoffFiles.item(at: folder.appendingPathComponent(file.path)) else { return .waiting }
            guard item.type == .typeRegular else { return .rejected("handoff.json 列出的「\(file.path)」不是一般的檔案") }
            guard item.size == file.size else { return .waiting }
        }
        // 列出的檔案都到齊了：最後看它是不是收得進來的場次
        let directory = SessionDirectory(url: folder)
        guard (try? Data(contentsOf: directory.metaURL)) != nil else { return .waiting }
        let meta: SessionMeta
        do {
            meta = try directory.loadMeta()
        } catch let error as SessionStoreError {
            return .rejected(error.description)
        } catch {
            return .rejected("session.json 讀不懂")
        }
        guard meta.id == manifest.id else { return .rejected("session.json 的 id 和 handoff.json 的不一樣") }
        guard meta.state != .recording else { return .rejected("這一場在手機上還沒有結束錄音") }
        return .ready(manifest)
    }

    /// `handoff.json` 本身的問題：`id` 和資料夾名稱對不上、路徑跑出場次資料夾、列出自己、沒有列出 `session.json`。
    private static func problem(with manifest: HandoffManifest, in folder: URL) -> String? {
        guard UUID(uuidString: folder.lastPathComponent) == manifest.id else {
            return "handoff.json 的 id（\(manifest.id.uuidString)）和資料夾名稱（\(folder.lastPathComponent)）對不上"
        }
        for file in manifest.files {
            guard staysInside(file.path) else { return "handoff.json 列出的路徑「\(file.path)」跑出了場次資料夾" }
            guard file.path != HandoffManifest.relativePath else { return "handoff.json 不應該列出它自己" }
        }
        guard manifest.files.contains(where: { $0.path == metaPath }) else {
            return "handoff.json 沒有列出 \(metaPath)"
        }
        return nil
    }

    /// 相對路徑是不是在場次資料夾裡面：不是空的、不是絕對路徑，每一段都不是空的、「.」或「..」。
    private static func staysInside(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
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
        guard let lock = try SessionLock.acquire(SessionDirectory(url: folder)) else { return .busy }
        // 拿到鎖之後才看收過了沒有：另一個 ThunderFlow 可能剛收完
        let ids = SessionLibrary.list(root: workingRoot).map(\.id) + SessionLibrary.list(root: libraryRoot).map(\.id)
        let received: SessionDirectory?
        do {
            received = ids.contains(manifest.id) ? nil : try copyIn(folder, manifest: manifest)
        } catch {
            lock.release()
            throw error
        }
        lock.release()
        guard let received else {
            do { try remove(folder) } catch { throw SessionHandoffError.cannotRemove(error.userFacingDescription) }
            return .alreadyReceived
        }
        // 移不走也不影響收進來的場次：下次看到時當成已經收過，再移一次
        try? remove(folder)
        return .received(received)
    }

    /// 暫存位置：工作目錄裡的 `.receiving/`。多一層，所以複製到一半就中斷時，
    /// 不會被當成工作目錄裡還沒做完結束處理的場次（那些只看工作目錄底下一層）。
    static let stagingFolderName = ".receiving"

    /// 複製到暫存位置、核對大小，再改名成 `<工作目錄>/<場次 id>/`（名稱被占用時加序號）。回傳收進來的場次。
    /// 失敗時刪掉暫存的複製；暫存位置空了就一起刪。
    private func copyIn(_ folder: URL, manifest: HandoffManifest) throws -> SessionDirectory {
        let fileManager = FileManager.default
        let stagingRoot = workingRoot.appendingPathComponent(Self.stagingFolderName, isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer {
            // 成功時暫存的複製已經改名搬走了
            try? fileManager.removeItem(at: staging)
            rmdir(stagingRoot.path)  // 空的才刪得掉
        }
        // 上次複製到一半就中斷留下的
        try? fileManager.removeItem(at: staging)

        let needed = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        if let available = try? stagingRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
            Int64(available) - needed < reservedSpace
        {
            throw SessionHandoffError.notEnoughSpace(needed: needed, available: Int64(available), reserved: reservedSpace)
        }
        // 只複製列出的檔案，加上 handoff.json 本身（說明這一場是從手機來的）
        for path in manifest.files.map(\.path) + [HandoffManifest.relativePath] {
            let target = staging.appendingPathComponent(path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: folder.appendingPathComponent(path), to: target)
        }
        // 帶過來的 handoff.json 和看過的那一份不一樣：手機剛好又交了一次，這次不收，下次再看
        let copiedManifest = try? HandoffManifest.decode(
            Data(contentsOf: staging.appendingPathComponent(HandoffManifest.relativePath)))
        guard copiedManifest == manifest else { throw SessionHandoffError.changedDuringCopy }
        for file in manifest.files {
            let size = HandoffFiles.item(at: staging.appendingPathComponent(file.path))?.size ?? -1
            guard size == file.size else {
                throw SessionHandoffError.sizeMismatch(path: file.path, expected: file.size, found: size)
            }
        }
        let destination = try SessionLibrary.move(
            staging, into: workingRoot, named: manifest.id.uuidString,
            stagingName: "\(Self.stagingFolderName)-\(manifest.id.uuidString)")
        return SessionDirectory(url: destination)
    }

    /// 看一次收件匣，收進每一份可以收的（`scan`、`receive`）。不會丟出錯誤：收件匣本身有問題（不存在、讀不到、
    /// 在 Library 裡面）與每一份沒收進來的原因都記在 `problems`。
    public func collect() -> InboxReport {
        var report = InboxReport()
        if let problem = Self.problem(inbox: inbox, library: libraryRoot) {
            report.problems.append(InboxReport.Problem(folder: inbox, reason: "\(problem)，請到「設定」重新選擇收件匣"))
            return report
        }
        let entries: [InboxEntry]
        do {
            entries = try scan()
        } catch {
            report.problems.append(InboxReport.Problem(folder: inbox, reason: Self.unreadable(error)))
            return report
        }
        for entry in entries {
            switch entry.status {
            case .waiting:
                report.waiting.append(entry.folder)
            case .rejected(let reason):
                report.problems.append(InboxReport.Problem(folder: entry.folder, reason: reason))
            case .ready(let manifest):
                do {
                    switch try receive(entry.folder, manifest: manifest) {
                    case .received(let directory):
                        report.received.append(
                            InboxReport.Received(id: manifest.id, directory: directory, from: manifest.from))
                    case .alreadyReceived:
                        report.alreadyReceived.append(manifest.id)
                    case .busy:
                        break
                    }
                } catch {
                    let reason: String
                    if case SessionHandoffError.cannotRemove = error {
                        reason = error.userFacingDescription
                    } else {
                        reason = "沒有收進來（\(error.userFacingDescription)），下次會再試"
                    }
                    report.problems.append(InboxReport.Problem(folder: entry.folder, reason: reason))
                }
            }
        }
        return report
    }

    /// 收件匣讀不到時的說明。
    private static func unreadable(_ error: any Error) -> String {
        if let code = (error as? CocoaError)?.code, code == .fileReadNoSuchFile || code == .fileNoSuchFile {
            return "找不到收件匣（可能被搬走、改名或刪掉了），請到「設定」重新選擇"
        }
        return "讀不到收件匣（\(error.userFacingDescription)）"
    }
}
