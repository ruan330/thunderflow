import Foundation

public enum SessionStoreError: Error, Equatable {
    /// 檔案是比較新版的 App 寫的，這一版讀不懂。
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// 一場錄音的資料夾。錄音中（工作目錄）和完成後（Library）用同一套結構：
///
///     <場次資料夾>/
///     └── .thunderflow/
///         ├── session.json    基本資料（小檔，清單頁只讀它）
///         ├── journal.jsonl   原始紀錄（只追加）
///         └── audio/          錄音中的 CAF 分段（合併成 m4a 後刪除）
public struct SessionDirectory: Sendable, Equatable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var hiddenDirectoryURL: URL { url.appendingPathComponent(".thunderflow", isDirectory: true) }
    public var metaURL: URL { hiddenDirectoryURL.appendingPathComponent("session.json") }
    public var journalURL: URL { hiddenDirectoryURL.appendingPathComponent("journal.jsonl") }
    public var audioDirectoryURL: URL { hiddenDirectoryURL.appendingPathComponent("audio", isDirectory: true) }

    /// 建立資料夾結構。已經存在也不算錯。
    public func create() throws {
        throw NotYetImplemented("SessionDirectory.create()")
    }

    /// 原子寫入 `session.json`：讀的人只會看到舊的完整內容或新的完整內容，不會看到寫到一半的檔。
    public func saveMeta(_ meta: SessionMeta) throws {
        throw NotYetImplemented("SessionDirectory.saveMeta(_:)")
    }

    /// 讀取 `session.json`。不認識的欄位會忽略，缺少的非必要欄位用預設值。
    public func loadMeta() throws -> SessionMeta {
        throw NotYetImplemented("SessionDirectory.loadMeta()")
    }
}
