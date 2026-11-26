import Foundation
import ThunderCore

/// Library：存放所有場次資料夾的使用者資料夾（DESIGN.md 5.9 節）。
///
/// 檔案就是資料：清單只靠掃描資料夾建立，沒有資料庫也沒有快取。場次用 `session.json` 裡的 `id` 識別，
/// 資料夾名稱只是給人看的，使用者在 Finder 裡改名或搬移都不會出問題。
public enum SessionLibrary {
    /// 預設的 Library 位置（D37、D38）。`home` 是使用者的家目錄。依序：
    ///
    /// 1. 舊的預設位置裡已經有場次：繼續用它（先看「文件/ThunderFlow」，再看「iCloud 雲碟/ThunderFlow」）。
    ///    不替使用者搬檔案，過去錄音也不會突然變空。
    /// 2. iPhone 版在這個 Apple 帳號用過（App 的 iCloud 空間在這台 Mac 上）：那個空間的 `Documents/`。
    ///    在 iCloud 雲碟裡顯示成帶 App 圖示的「ThunderFlow」，手機不用選資料夾就看得到過去錄音。
    /// 3. 這台 Mac 有 iCloud 雲碟（`~/Library/Mobile Documents/com~apple~CloudDocs` 存在）：iCloud 雲碟裡的「ThunderFlow」。
    /// 4. 否則：「文件/ThunderFlow」。
    ///
    /// 錄音中只寫本機的工作目錄（5.9 節），按停止、搬進 Library 之後才上傳。
    /// App 第一次決定之後就記下來（設定裡的資料夾），之後不會因為 iCloud 雲碟暫時不在而換位置。
    public static func defaultRoot(home: URL) -> URL {
        let documents = home.appendingPathComponent("Documents/ThunderFlow", isDirectory: true)
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let driveLibrary = drive.appendingPathComponent("ThunderFlow", isDirectory: true)
        for existing in [documents, driveLibrary] where !list(root: existing).isEmpty { return existing }
        if isDirectory(SessionHandoff.macContainer(home: home)) { return SessionHandoff.macLibrary(home: home) }
        if isDirectory(drive) { return driveLibrary }
        return documents
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public struct Item: Sendable, Equatable, Identifiable {
        /// 場次的 id（`session.json` 裡的 `id`）。
        public var id: UUID
        public var directory: SessionDirectory
        public var meta: SessionMeta

        public init(id: UUID, directory: SessionDirectory, meta: SessionMeta) {
            self.id = id
            self.directory = directory
            self.meta = meta
        }
    }

    /// 列出 `root` 底下一層的場次，由新到舊（依開始時間；相同時依資料夾路徑）。
    ///
    /// 只讀每個資料夾裡的 `.thunderflow/session.json`。讀不懂的資料夾（沒有 `session.json`、不是合法的 JSON、
    /// 比這一版新的格式）、不是資料夾的東西、名稱以「.」開頭的項目都會略過，不影響其他場次。
    /// `root` 不存在時回傳空陣列。工作目錄用同一套結構，所以也可以用它找出還沒做完結束處理的場次。
    public static func list(root: URL) -> [Item] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var items: [Item] = []
        for name in names where !name.hasPrefix(".") {
            let directory = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
            guard let meta = try? directory.loadMeta() else { continue }
            items.append(Item(id: meta.id, directory: directory, meta: meta))
        }
        return items.sorted(by: newestFirst)
    }

    /// 過去錄音的清單（DESIGN.md 4.5 節：包含還在處理中的場次）：Library 裡的場次，加上工作目錄裡已經停止錄音、
    /// 還沒搬進 Library 的場次（結束處理中，或前幾步處理失敗而留在工作目錄），由新到舊。
    ///
    /// - 工作目錄裡還在錄音（或中斷了還沒復原）的場次不列出。
    /// - 同一場兩邊都有（搬進 Library 的途中）時只列 Library 的那一份。
    /// - 先讀工作目錄、再讀 Library：搬移途中的場次至少會出現在其中一邊，不會從清單上消失一下
    ///   （消失的話，正在看的詳細頁會被關掉、播放停止）。
    public static func list(library: URL, working: URL) -> [Item] {
        let unpublished = list(root: working).filter { $0.meta.state != .recording }
        let published = list(root: library)
        let publishedIDs = Set(published.map(\.id))
        return (published + unpublished.filter { !publishedIDs.contains($0.id) }).sorted(by: newestFirst)
    }

    /// 由新到舊（依開始時間；相同時依資料夾路徑）。
    private static func newestFirst(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.meta.startedAt != rhs.meta.startedAt { return lhs.meta.startedAt > rhs.meta.startedAt }
        return lhs.directory.url.path < rhs.directory.url.path
    }

    /// 場次資料夾的名稱：開始時間（`timeZone` 的當地時間）加上標題，例如
    /// `2026-12-02 1030 Building Agents with Bedrock`；沒有標題時是 `2026-12-02 1030 未命名`。
    ///
    /// 標題裡不能當檔名的字元（`/`、`:`、控制字元）與換行換成空白，連續的空白收成一個，頭尾的空白去掉；
    /// 最多取 80 個字元（而且不超過 200 個 UTF-16 單位：檔名的上限是 255 個，要留給日期與重名時的序號）。
    public static func folderName(for meta: SessionMeta, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: meta.startedAt)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let stamp =
            "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2)) "
            + "\(padded(parts.hour, 2))\(padded(parts.minute, 2))"
        return "\(stamp) \(fileNameTitle(meta.title))"
    }

    /// `root` 底下還沒有被占用的位置：`name`；已經有同名的東西時依序試 `name 2`、`name 3`……
    public static func availableURL(named name: String, in root: URL) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while isTaken(candidate) {
            candidate = root.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    // MARK: 名稱

    private static let maximumTitleCharacters = 80
    private static let maximumTitleUnits = 200

    /// 標題變成資料夾名稱：去掉檔名不允許的字元、限制長度；空的用「未命名」。工作坊教材的資料夾也用它（`WorkshopDownloader`）。
    static func fileNameTitle(_ title: String) -> String {
        let cleaned = String(
            title.map { character -> Character in
                if character == "/" || character == ":" || character.isWhitespace { return " " }
                if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return " " }
                return character
            })
        var name = String(cleaned.split(separator: " ").joined(separator: " ").prefix(maximumTitleCharacters))
        // 檔案系統以分解後的 UTF-16 長度計算檔名上限（實測 APFS 是 255 個單位）
        while name.decomposedStringWithCanonicalMapping.utf16.count > maximumTitleUnits { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? SessionMeta.untitledTitle : name
    }

    /// 這個位置是不是已經有東西了（不跟著符號連結走，壞掉的連結也算占用）。
    private static func isTaken(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    // MARK: 搬移

    /// `folder` 是不是在 `root` 裡面（任何一層）。兩邊都解析成實際的路徑再比較；`root` 不存在時一定不是。
    static func contains(_ folder: URL, in root: URL) -> Bool {
        guard let folderPath = realPath(folder), let rootPath = realPath(root) else { return false }
        return folderPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// 把資料夾 `source` 搬進 `parent`（必須已經存在），取名 `name`；名稱被占用時加序號。回傳新的位置。
    ///
    /// 不會覆蓋既有的東西：改名時要求目的地不存在（`RENAME_EXCL`），剛好被別人占走就換下一個名稱。
    /// 同一個磁碟區上是一次原子的改名。`source` 與 `parent` 在不同的磁碟區時改用複製：先複製到 `parent` 裡
    /// 名稱以「.」開頭的暫存資料夾（`stagingName`），複製完才改成正式的名稱，最後刪掉來源；
    /// 中途被中斷只會留下隱藏的暫存資料夾（下次會先清掉），不會出現看起來完整的半成品。
    static func move(_ source: URL, into parent: URL, named name: String, stagingName: String) throws -> URL {
        var origin = source
        var copied = false
        for _ in 0..<10_000 {
            let destination = availableURL(named: name, in: parent)
            if renamex_np(origin.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                if copied { try? FileManager.default.removeItem(at: source) }
                return destination
            }
            var code = errno
            if code == ENOTSUP {
                // 這個檔案系統不支援 RENAME_EXCL：目的地剛剛確認過不存在，改用一般的改名
                if rename(origin.path, destination.path) == 0 {
                    if copied { try? FileManager.default.removeItem(at: source) }
                    return destination
                }
                code = errno
            }
            switch code {
            case EEXIST, ENOTEMPTY:
                continue
            case EXDEV where !copied:
                let staging = parent.appendingPathComponent(stagingName, isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.copyItem(at: source, to: staging)
                origin = staging
                copied = true
            default:
                if copied { try? FileManager.default.removeItem(at: origin) }
                throw posixError(code, path: destination.path)
            }
        }
        if copied { try? FileManager.default.removeItem(at: origin) }
        throw posixError(EEXIST, path: parent.appendingPathComponent(name).path)
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(path)：\(String(cString: strerror(code)))"])
    }
}
