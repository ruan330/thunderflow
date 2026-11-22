import Foundation

public enum SessionSummaryError: Error, Equatable {
    /// 文字模型的輸出不是預期的 JSON 物件。
    case notJSON
}

extension SessionSummaryError: CustomStringConvertible, LocalizedError {
    /// 給人看的說明（放進橫幅的句子裡，句尾不加句號）。
    public var description: String {
        switch self {
        case .notJSON: "文字模型回傳的摘要格式不對（不是 JSON）"
        }
    }

    public var errorDescription: String? { description }
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

        private enum CodingKeys: String, CodingKey {
            case startSec = "start_sec", title, summary
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                startSec: try container.decodeIfPresent(Double.self, forKey: .startSec) ?? 0,
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "")
        }
    }

    public struct Term: Sendable, Equatable, Codable {
        public var en: String
        public var zh: String

        public init(en: String, zh: String) {
            self.en = en
            self.zh = zh
        }

        private enum CodingKeys: String, CodingKey {
            case en, zh
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                en: try container.decodeIfPresent(String.self, forKey: .en) ?? "",
                zh: try container.decodeIfPresent(String.self, forKey: .zh) ?? "")
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

    private enum CodingKeys: String, CodingKey {
        case title, oneLiner = "one_liner", keyPoints = "key_points", chapters, glossary, actionItems = "action_items"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            oneLiner: try container.decodeIfPresent(String.self, forKey: .oneLiner) ?? "",
            keyPoints: try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? [],
            chapters: try container.decodeIfPresent([Chapter].self, forKey: .chapters) ?? [],
            glossary: try container.decodeIfPresent([Term].self, forKey: .glossary) ?? [],
            actionItems: try container.decodeIfPresent([String].self, forKey: .actionItems) ?? [])
    }

    /// 給文字模型的結構化輸出格式：嚴格的 JSON Schema（每個欄位都必填、不允許多餘的欄位）。
    public static let schema = TextSchema(
        name: "session_summary",
        json: """
            {
              "type": "object",
              "properties": {
                "title": { "type": "string", "description": "這一場的標題，簡短具體" },
                "one_liner": { "type": "string", "description": "一句話總結" },
                "key_points": { "type": "array", "description": "重點，每個一句話", "items": { "type": "string" } },
                "chapters": {
                  "type": "array",
                  "description": "章節，依時間先後",
                  "items": {
                    "type": "object",
                    "properties": {
                      "start_sec": { "type": "integer", "description": "這一章開始的時間（秒），必須落在錄音長度之內" },
                      "title": { "type": "string" },
                      "summary": { "type": "string" }
                    },
                    "required": ["start_sec", "title", "summary"],
                    "additionalProperties": false
                  }
                },
                "glossary": {
                  "type": "array",
                  "description": "名詞對照；沒有就是空陣列",
                  "items": {
                    "type": "object",
                    "properties": { "en": { "type": "string" }, "zh": { "type": "string" } },
                    "required": ["en", "zh"],
                    "additionalProperties": false
                  }
                },
                "action_items": { "type": "array", "description": "待辦事項；沒有就是空陣列", "items": { "type": "string" } }
              },
              "required": ["title", "one_liner", "key_points", "chapters", "glossary", "action_items"],
              "additionalProperties": false
            }
            """)

    /// 解析文字模型的輸出。
    ///
    /// 前後的空白、包在外面的 Markdown 程式碼區塊都容許；每個字串去掉頭尾的空白並收成一行，
    /// 空的重點、待辦事項與沒有英文的名詞會被拿掉。不是 JSON 物件、或欄位的型別不對時丟出
    /// `SessionSummaryError.notJSON`。
    public static func parse(_ output: String) throws -> SessionSummary {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        // 外面包了別的東西（例如程式碼區塊）：取第一個「{」到最後一個「}」
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            candidates.append(String(trimmed[start...end]))
        }
        let decoder = JSONDecoder()
        for candidate in candidates {
            if let summary = try? decoder.decode(SessionSummary.self, from: Data(candidate.utf8)) {
                return summary.tidied()
            }
        }
        throw SessionSummaryError.notJSON
    }

    /// 章節時間必須落在錄音長度之內：剔除小於 0 或超過 `durationSeconds` 的章節，其餘依時間排序
    /// （時間相同的維持原來的順序）。
    public func keepingChapters(within durationSeconds: Double) -> SessionSummary {
        var result = self
        result.chapters =
            chapters.enumerated()
            .filter { $0.element.startSec >= 0 && $0.element.startSec <= durationSeconds }
            .sorted { ($0.element.startSec, $0.offset) < ($1.element.startSec, $1.offset) }
            .map(\.element)
        return result
    }

    /// 沒有實質內容：沒有一句話總結、沒有重點、也沒有章節。
    public var isEmpty: Bool {
        oneLiner.isEmpty && keyPoints.isEmpty && chapters.isEmpty
    }

    /// 讀取 `summary.json`。檔案不存在或不是合法的 JSON 會丟出錯誤。
    public static func read(_ url: URL) throws -> SessionSummary {
        try JSONDecoder().decode(SessionSummary.self, from: Data(contentsOf: url))
    }

    /// 原子寫入 `summary.json`：排版過、欄位依字母排序的 JSON，以一個換行結尾。
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        try FileIO.writeAtomically(data, to: url)
    }

    /// 每個字串去掉頭尾的空白並收成一行；空的項目拿掉。
    private func tidied() -> SessionSummary {
        SessionSummary(
            title: TextFlow.singleLine(title),
            oneLiner: TextFlow.singleLine(oneLiner),
            keyPoints: keyPoints.map(TextFlow.singleLine).filter { !$0.isEmpty },
            chapters: chapters.map {
                Chapter(
                    startSec: $0.startSec, title: TextFlow.singleLine($0.title), summary: TextFlow.singleLine($0.summary))
            }.filter { !$0.title.isEmpty || !$0.summary.isEmpty },
            glossary: glossary.map { Term(en: TextFlow.singleLine($0.en), zh: TextFlow.singleLine($0.zh)) }
                .filter { !$0.en.isEmpty },
            actionItems: actionItems.map(TextFlow.singleLine).filter { !$0.isEmpty })
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
        let line = TextFlow.singleLine
        var title = line(meta.title)
        if title.isEmpty { title = line(summary.title) }
        if title.isEmpty { title = SessionMeta.untitledTitle }

        var text = SessionHeader.render(title: title, meta: meta, timeZone: timeZone)
        if !line(summary.oneLiner).isEmpty { text += "\n\(line(summary.oneLiner))\n" }
        if !summary.keyPoints.isEmpty {
            text += "\n## 重點\n\n" + summary.keyPoints.map { "- \(line($0))\n" }.joined()
        }
        if !summary.chapters.isEmpty {
            text += "\n## 章節\n"
            for chapter in summary.chapters {
                text += "\n### \(Timecode.clock(chapter.startSec)) \(line(chapter.title))"
                    .trimmingCharacters(in: .whitespaces)
                text += "\n"
                if !line(chapter.summary).isEmpty { text += "\(line(chapter.summary))\n" }
            }
        }
        if !summary.glossary.isEmpty {
            text += "\n## 名詞對照\n\n"
            text += summary.glossary.map { term in
                line(term.zh).isEmpty ? "- \(line(term.en))\n" : "- \(line(term.en))：\(line(term.zh))\n"
            }.joined()
        }
        if !summary.actionItems.isEmpty {
            text += "\n## 待辦事項\n\n" + summary.actionItems.map { "- \(line($0))\n" }.joined()
        }
        return text
    }
}
