import Foundation

/// 結束處理的成品（DESIGN.md 5.9 節）：
///
///     <場次資料夾>/
///     ├── recording.m4a
///     ├── transcript.md
///     ├── summary.md
///     └── .thunderflow/
///         ├── session.json
///         ├── journal.jsonl
///         ├── blocks.jsonl    一行一段：開始時間、英文、中文
///         └── summary.json    摘要的結構化資料（畫面讀它，`summary.md` 由它排版）
extension SessionDirectory {
    public var blocksURL: URL { hiddenDirectoryURL.appendingPathComponent("blocks.jsonl") }
    public var summaryDataURL: URL { hiddenDirectoryURL.appendingPathComponent("summary.json") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { url.appendingPathComponent("summary.md") }
    public var recordingURL: URL { url.appendingPathComponent("recording.m4a") }

    /// 原子寫入文字檔（UTF-8），給 `transcript.md`、`summary.md` 用：
    /// 先寫進同一個資料夾裡的暫存檔並 fsync，再以 rename(2) 取代原檔；成功之後不留下暫存檔。
    public func writeText(_ text: String, to url: URL) throws {
        // 尚未實作（M3）
    }
}
