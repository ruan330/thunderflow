import Foundation
import Testing
import ThunderCore
import ThunderTestKit

private let taipei = TimeZone(identifier: "Asia/Taipei") ?? .gmt

@Suite("摘要：結構、JSON 與 summary.md")
struct SessionSummaryTests {
    private let sample = SessionSummary(
        title: "用 AgentCore 打造 Agent",
        oneLiner: "AgentCore 讓 Agent 從原型走到正式環境。",
        keyPoints: ["AgentCore 有 3 個核心元件：runtime、gateway、memory", "每個工作階段都在各自隔離的環境執行"],
        chapters: [
            .init(startSec: 12, title: "開場與問題定義", summary: "為什麼 Agent 很難上線。"),
            .init(startSec: 520, title: "AgentCore 的三個元件", summary: "逐一介紹 runtime、gateway 與 memory。"),
            .init(startSec: 3_723, title: "問與答"),
        ],
        glossary: [.init(en: "agent runtime", zh: "代理程式的執行環境"), .init(en: "session isolation", zh: "工作階段隔離")],
        actionItems: ["試用 AgentCore Runtime", "讀一遍 AgentCore 的文件"])

    private let sampleJSON = """
        {
          "title": "用 AgentCore 打造 Agent",
          "one_liner": "AgentCore 讓 Agent 從原型走到正式環境。",
          "key_points": ["AgentCore 有 3 個核心元件：runtime、gateway、memory", "每個工作階段都在各自隔離的環境執行"],
          "chapters": [
            { "start_sec": 12, "title": "開場與問題定義", "summary": "為什麼 Agent 很難上線。" },
            { "start_sec": 520, "title": "AgentCore 的三個元件", "summary": "逐一介紹 runtime、gateway 與 memory。" },
            { "start_sec": 3723, "title": "問與答", "summary": "" }
          ],
          "glossary": [
            { "en": "agent runtime", "zh": "代理程式的執行環境" },
            { "en": "session isolation", "zh": "工作階段隔離" }
          ],
          "action_items": ["試用 AgentCore Runtime", "讀一遍 AgentCore 的文件"]
        }
        """

    @Test("JSON 的欄位名稱和設計文件一致：讀得懂文件的格式，寫出來也是同樣的欄位")
    func jsonKeys() throws {
        #expect(try JSONDecoder().decode(SessionSummary.self, from: Data(sampleJSON.utf8)) == sample)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample))
        let object = try #require(encoded as? [String: Any])
        #expect(Set(object.keys) == ["title", "one_liner", "key_points", "chapters", "glossary", "action_items"])
        let chapter = try #require((object["chapters"] as? [[String: Any]])?.first)
        #expect(Set(chapter.keys) == ["start_sec", "title", "summary"])
        #expect(chapter["start_sec"] as? Int == 12)
        let term = try #require((object["glossary"] as? [[String: Any]])?.first)
        #expect(Set(term.keys) == ["en", "zh"])
    }

    @Test("解析文字模型的輸出：容許前後的空白與程式碼區塊，字串收成一行，空的項目拿掉，缺少的欄位用預設值")
    func parsesModelOutput() throws {
        #expect(try SessionSummary.parse(sampleJSON) == sample)
        #expect(try SessionSummary.parse("\n\n  " + sampleJSON + "  \n") == sample)
        #expect(try SessionSummary.parse("```json\n" + sampleJSON + "\n```") == sample)

        let untidy = """
            {"title":"  標題\\n第二行 ","one_liner":" 一句話。 ","key_points":["  重點  ","","   "],
             "chapters":[{"start_sec":5,"title":" 第一章 ","summary":""},{"start_sec":9,"title":"","summary":" "}],
             "glossary":[{"en":" term ","zh":" 名詞 "},{"en":"","zh":"沒有英文"}],"action_items":["", " 做這件事 "]}
            """
        #expect(
            try SessionSummary.parse(untidy)
                == SessionSummary(
                    title: "標題第二行", oneLiner: "一句話。", keyPoints: ["重點"],
                    chapters: [.init(startSec: 5, title: "第一章")], glossary: [.init(en: "term", zh: "名詞")],
                    actionItems: ["做這件事"]))

        #expect(try SessionSummary.parse("{\"one_liner\":\"只有一句話\"}") == SessionSummary(oneLiner: "只有一句話"))
        #expect(try SessionSummary.parse("{}") == SessionSummary())
    }

    @Test(
        "不是 JSON 物件、或欄位的型別不對：丟出錯誤",
        arguments: ["", "這不是 JSON", "[1, 2, 3]", "\"只是字串\"", "{\"key_points\":\"不是陣列\"}", "{\"title\": 沒有引號}"])
    func rejectsInvalidOutput(output: String) {
        #expect(throws: SessionSummaryError.notJSON) { try SessionSummary.parse(output) }
    }

    @Test("章節時間超出錄音長度的會被剔除，其餘依時間排序；時間相同的維持原來的順序")
    func keepsChaptersInsideTheRecording() {
        let summary = SessionSummary(chapters: [
            .init(startSec: 34, title: "第三"), .init(startSec: 60, title: "剛好在結尾"), .init(startSec: 8, title: "第二"),
            .init(startSec: 60.5, title: "超過了"), .init(startSec: -5, title: "負的"), .init(startSec: 0, title: "第一"),
            .init(startSec: 34, title: "第四"),
        ])

        #expect(summary.keepingChapters(within: 60).chapters.map(\.title) == ["第一", "第二", "第三", "第四", "剛好在結尾"])
        #expect(summary.keepingChapters(within: 0).chapters.map(\.title) == ["第一"])
        // 其他欄位不受影響
        #expect(sample.keepingChapters(within: 600).chapters.map(\.startSec) == [12, 520])
        #expect(sample.keepingChapters(within: 600).keyPoints == sample.keyPoints)
    }

    @Test("沒有一句話總結、重點與章節的摘要算是空的")
    func emptiness() {
        #expect(SessionSummary().isEmpty)
        #expect(SessionSummary(title: "只有標題", glossary: [.init(en: "a", zh: "b")], actionItems: ["x"]).isEmpty)
        #expect(!SessionSummary(oneLiner: "一句話").isEmpty)
        #expect(!SessionSummary(keyPoints: ["重點"]).isEmpty)
        #expect(!SessionSummary(chapters: [.init(startSec: 0, title: "章節")]).isEmpty)
        #expect(!sample.isEmpty)
    }

    @Test("結構化輸出的格式是嚴格的 JSON Schema：每個欄位都必填，不允許多餘的欄位")
    func strictSchema() throws {
        #expect(SessionSummary.schema.name == "session_summary")
        let parsed = try JSONSerialization.jsonObject(with: Data(SessionSummary.schema.json.utf8))
        let schema = try #require(parsed as? [String: Any])
        let keys = ["title", "one_liner", "key_points", "chapters", "glossary", "action_items"]
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == keys)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(Set(properties.keys) == Set(keys))
        #expect(properties["title"]?["type"] as? String == "string")
        #expect(properties["one_liner"]?["type"] as? String == "string")
        for key in ["key_points", "action_items"] {
            #expect(properties[key]?["type"] as? String == "array")
            #expect((properties[key]?["items"] as? [String: Any])?["type"] as? String == "string")
        }
        for (key, fields) in [("chapters", ["start_sec", "title", "summary"]), ("glossary", ["en", "zh"])] {
            #expect(properties[key]?["type"] as? String == "array")
            let items = try #require(properties[key]?["items"] as? [String: Any])
            #expect(items["type"] as? String == "object")
            #expect(items["additionalProperties"] as? Bool == false)
            #expect(items["required"] as? [String] == fields)
            #expect(Set((items["properties"] as? [String: Any] ?? [:]).keys) == Set(fields))
        }
    }

    @Test("summary.md 的輸出完全符合預期：一句話總結、重點、章節、名詞對照、待辦事項")
    func rendersMarkdown() {
        let meta = SessionMeta(
            title: "Building Agents with Bedrock", startedAt: Date(timeIntervalSince1970: 1_796_178_600),
            source: "系統音訊", durationSeconds: 6_125)

        let expected = """
            # Building Agents with Bedrock
            2026-12-02 10:30 · 1:42:05 · 系統音訊

            AgentCore 讓 Agent 從原型走到正式環境。

            ## 重點

            - AgentCore 有 3 個核心元件：runtime、gateway、memory
            - 每個工作階段都在各自隔離的環境執行

            ## 章節

            ### 00:00:12 開場與問題定義
            為什麼 Agent 很難上線。

            ### 00:08:40 AgentCore 的三個元件
            逐一介紹 runtime、gateway 與 memory。

            ### 01:02:03 問與答

            ## 名詞對照

            - agent runtime：代理程式的執行環境
            - session isolation：工作階段隔離

            ## 待辦事項

            - 試用 AgentCore Runtime
            - 讀一遍 AgentCore 的文件

            """
        #expect(SummaryMarkdown.render(meta: meta, summary: sample, timeZone: taipei) == expected)
    }

    @Test("沒有內容的部分整段省略；場次沒有標題時用摘要的標題，都沒有就是「未命名」")
    func omitsEmptySections() {
        let untitled = SessionMeta(startedAt: Date(timeIntervalSince1970: 1_796_178_600), durationSeconds: 65)

        #expect(
            SummaryMarkdown.render(
                meta: untitled, summary: SessionSummary(title: "摘要取的標題", oneLiner: "只有一句話。"), timeZone: taipei)
                == "# 摘要取的標題\n2026-12-02 10:30 · 1:05\n\n只有一句話。\n")
        #expect(
            SummaryMarkdown.render(
                meta: untitled, summary: SessionSummary(actionItems: ["寄出會議紀錄"]), timeZone: taipei)
                == "# 未命名\n2026-12-02 10:30 · 1:05\n\n## 待辦事項\n\n- 寄出會議紀錄\n")
    }

    @Test("summary.json：寫進去再讀出來一模一樣；原子寫入，不留暫存檔")
    func fileRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("summary.json")

        try SessionSummary(oneLiner: "第一版").write(to: url)
        try sample.write(to: url)

        #expect(try SessionSummary.read(url) == sample)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"one_liner\" : \"AgentCore 讓 Agent 從原型走到正式環境。\""))
        #expect(text.hasSuffix("}\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["summary.json"])
        #expect(throws: (any Error).self) { try SessionSummary.read(tmp.url.appendingPathComponent("missing.json")) }
    }
}
