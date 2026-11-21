import Foundation
import ThunderCore

/// Library：存放所有場次資料夾的使用者資料夾（DESIGN.md 5.9 節）。
///
/// 檔案就是資料：清單只靠掃描資料夾建立，沒有資料庫也沒有快取。場次用 `session.json` 裡的 `id` 識別，
/// 資料夾名稱只是給人看的，使用者在 Finder 裡改名或搬移都不會出問題。
public enum SessionLibrary {
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

    /// 列出 `root` 底下一層的場次，由新到舊。只讀每個資料夾裡的 `session.json`；
    /// 讀不懂的資料夾會略過，`root` 不存在時回傳空陣列。
    public static func list(root: URL) -> [Item] {
        // 尚未實作（M3）
        []
    }

    /// 場次資料夾的名稱：開始時間（`timeZone` 的當地時間）加上標題，例如
    /// `2026-12-02 1030 Building Agents with Bedrock`；沒有標題時是 `2026-12-02 1030 未命名`。
    /// 不能當檔名的字元換成空白，連續的空白收成一個，標題最多取 80 個字元。
    public static func folderName(for meta: SessionMeta, timeZone: TimeZone = .current) -> String {
        // 尚未實作（M3）
        ""
    }

    /// `root` 底下還沒有被占用的位置：`name`；已經有同名的東西時依序試 `name 2`、`name 3`……
    public static func availableURL(named name: String, in root: URL) -> URL {
        // 尚未實作（M3）
        root.appendingPathComponent(name, isDirectory: true)
    }
}
