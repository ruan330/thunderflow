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

    /// 建立資料夾結構（場次資料夾、`.thunderflow/`、`.thunderflow/audio/`）。已經存在也不算錯。
    /// 不會建立 `session.json` 與日誌，那是 `saveMeta` 與 `JournalWriter` 的事。
    public func create() throws {
        try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
    }

    /// 原子寫入 `session.json`：讀的人只會看到舊的完整內容或新的完整內容，不會看到寫到一半的檔。
    ///
    /// 先寫進 `.thunderflow/` 裡的暫存檔並 fsync，再以 rename(2) 取代原檔；成功之後不留下暫存檔。
    /// 內容是排版過、欄位依字母排序的 JSON，日期是 ISO 8601（精確到秒），斜線不跳脫。
    public func saveMeta(_ meta: SessionMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(meta)
        data.append(UInt8(ascii: "\n"))
        try FileIO.writeAtomically(data, to: metaURL)
    }

    /// 讀取 `session.json`。不認識的欄位會忽略，缺少的非必要欄位用預設值。
    /// 檔案不存在或不是合法的 JSON 會丟出錯誤；比這一版新的格式丟出
    /// `SessionStoreError.unsupportedSchemaVersion`。
    public func loadMeta() throws -> SessionMeta {
        let data = try Data(contentsOf: metaURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMeta.self, from: data)
    }
}
