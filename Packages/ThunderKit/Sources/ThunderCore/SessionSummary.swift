import Foundation

public enum SessionSummaryError: Error, Equatable {
    /// 文字模型的輸出不是預期的 JSON 物件。
    case notJSON
}

/// 一場的摘要（DESIGN.md 5.8 節）。文字模型依 `schema` 輸出 JSON，由 App 自己排版成 `summary.md` 與畫面。
///
/// JSON 的欄位名稱：
///
///     {
///       "title": "string",
///       "one_liner": "string",
///       "key_points": ["string"],
///       "chapters": [{ "start_sec": 0, "title": "string", "summary": "string" }],
///       "glossary": [{ "en": "string", "zh": "string" }],
///       "action_items": ["string"]
///     }
///
/// 讀取時缺少的欄位用預設值（空字串、空陣列、0），不認識的欄位忽略。
public struct SessionSummary: Sendable, Equatable, Codable {
    public struct Chapter: Sendable, Equatable, Codable {
        /// 這一章開始的時間（音訊時間，秒）。
        public var startSec: Double
        public var title: String
        public var summary: String

        public init(startSec: Double, title: String, summary: String = "") {
            self.startSec = startSec
            self.title = title
            self.summary = summary
        }
    }

    public struct Term: Sendable, Equatable, Codable {
        public var en: String
        public var zh: String

        public init(en: String, zh: String) {
            self.en = en
            self.zh = zh
        }
    }

    /// 這一場的標題。使用者沒有命名的場次用它自動命名。
    public var title: String
    /// 一句話總結。清單頁顯示的就是它。
    public var oneLiner: String
    public var keyPoints: [String]
    public var chapters: [Chapter]
    public var glossary: [Term]
    public var actionItems: [String]

    public init(
        title: String = "",
        oneLiner: String = "",
        keyPoints: [String] = [],
        chapters: [Chapter] = [],
        glossary: [Term] = [],
        actionItems: [String] = []
    ) {
        self.title = title
        self.oneLiner = oneLiner
        self.keyPoints = keyPoints
        self.chapters = chapters
        self.glossary = glossary
        self.actionItems = actionItems
    }

    /// 給文字模型的結構化輸出格式：嚴格的 JSON Schema（每個欄位都必填、不允許多餘的欄位）。
    public static let schema = TextSchema(name: "", json: "{}")  // 尚未實作（M3）

    /// 解析文字模型的輸出。
    ///
    /// 前後的空白、包在外面的 Markdown 程式碼區塊都容許；每個字串去掉頭尾的空白並收成一行，
    /// 空的重點、待辦事項與沒有英文的名詞會被拿掉。不是 JSON 物件、或欄位的型別不對時丟出
    /// `SessionSummaryError.notJSON`。
    public static func parse(_ output: String) throws -> SessionSummary {
        // 尚未實作（M3）
        SessionSummary()
    }

    /// 章節時間必須落在錄音長度之內：剔除小於 0 或超過 `durationSeconds` 的章節，其餘依時間排序
    /// （時間相同的維持原來的順序）。
    public func keepingChapters(within durationSeconds: Double) -> SessionSummary {
        // 尚未實作（M3）
        self
    }

    /// 沒有實質內容：沒有一句話總結、沒有重點、也沒有章節。
    public var isEmpty: Bool {
        // 尚未實作（M3）
        false
    }

    /// 讀取 `summary.json`。檔案不存在或不是合法的 JSON 會丟出錯誤。
    public static func read(_ url: URL) throws -> SessionSummary {
        // 尚未實作（M3）
        SessionSummary()
    }

    /// 原子寫入 `summary.json`：排版過、欄位依字母排序的 JSON，以一個換行結尾。
    public func write(to url: URL) throws {
        // 尚未實作（M3）
    }
}

/// 把摘要排成 `summary.md`。
///
///     # Building Agents with Bedrock
///     2026-12-02 10:30 · 58:12 · 系統音訊
///
///     AgentCore 讓 Agent 從原型走到正式環境。
///
///     ## 重點
///
///     - …
///
///     ## 章節
///
///     ### 00:00:12 開場與問題定義
///     這一章的摘要。
///
///     ## 名詞對照
///
///     - agent runtime：代理程式的執行環境
///
///     ## 待辦事項
///
///     - …
///
/// - 前兩行和 `transcript.md` 相同。標題用場次的標題；場次沒有標題時用摘要的標題，兩者都沒有就是「未命名」。
/// - 沒有內容的部分（一句話總結、重點、章節、名詞對照、待辦事項）整段省略。
/// - 檔案以一個換行結尾。
public enum SummaryMarkdown {
    public static func render(meta: SessionMeta, summary: SessionSummary, timeZone: TimeZone = .current) -> String {
        // 尚未實作（M3）
        ""
    }
}
