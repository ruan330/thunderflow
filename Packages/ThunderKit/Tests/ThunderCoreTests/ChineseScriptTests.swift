import Testing
import ThunderCore

@Suite("簡體字檢查")
struct ChineseScriptTests {
    @Test("台灣繁體的技術文字不會被誤判", arguments: [
        "今天我想談談，我們如何讓打造可上線的代理程式變得更容易。",
        "Amazon Bedrock AgentCore 提供 3 個核心元件：執行環境、閘道與記憶體。",
        "這個無伺服器的端點預設會在 3 個可用區域之間自動擴充，延遲降低了 30%。",
        "請把資料寫進資料庫之後，再呼叫推論的 API；權杖的數量會影響費用。",
        "他們只花了幾個月，就把軟體從舊的架構搬到新的平台上，而且沒有停機。",
        "皇后、里長、乾淨、頭髮、發生、只有、台灣、才能、松山、姓范、划船、圖表、這麼、甚麼",
        "",
        "Plain English text with numbers 12345.",
    ])
    func traditional(text: String) {
        #expect(!ChineseScript.containsSimplified(text), "誤判的字：\(ChineseScript.simplifiedCharacters(in: text))")
    }

    @Test("簡體字會被抓到", arguments: [
        "这是默认的服务器。",
        "我们今天来谈谈无服务器架构。",
        "數據已經寫入数据库。",
        "什么时候开始？",
        "台湾的开发者",
    ])
    func simplified(text: String) {
        #expect(ChineseScript.containsSimplified(text))
    }

    @Test("列出出現的簡體字：依出現順序，不重複")
    func listsCharacters() {
        #expect(ChineseScript.simplifiedCharacters(in: "这个问题，这个时候") == ["这", "个", "问", "题", "时"])
        #expect(ChineseScript.simplifiedCharacters(in: "這個問題").isEmpty)
    }
}
