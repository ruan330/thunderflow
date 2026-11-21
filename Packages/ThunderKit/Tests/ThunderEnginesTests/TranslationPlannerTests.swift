import Foundation
import Testing
import ThunderCore
import ThunderEngines

/// 把 `TranslationPlanner` 回傳的動作收集起來，方便檢查。
private struct PlanDriver {
    var planner: TranslationPlanner
    private(set) var effects: [TranslationPlanner.Effect] = []

    init(_ configure: (inout TranslationPlanner.Configuration) -> Void = { _ in }) {
        var configuration = TranslationPlanner.Configuration()
        configure(&configuration)
        planner = TranslationPlanner(configuration: configuration)
    }

    @discardableResult
    mutating func run(_ new: [TranslationPlanner.Effect]) -> [TranslationPlanner.Effect] {
        effects += new
        return new
    }

    @discardableResult
    mutating func finish(_ segment: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.segmentFinished(segment, text: text, at: now))
    }

    @discardableResult
    mutating func complete(_ request: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.completed(request: request, text: text, at: now))
    }

    var started: [(request: Int, content: TextRequest)] {
        effects.compactMap { if case .start(let request, let content) = $0 { (request, content) } else { nil } }
    }

    /// 第 `index` 個送出的請求的內容。還沒有送出這麼多個就讓測試失敗（而不是當掉）。
    func content(_ index: Int) throws -> TextRequest {
        let all = started
        return try #require(index < all.count ? all[index].content : nil, "還沒有送出第 \(index) 個請求")
    }

    var cancelled: [Int] {
        effects.compactMap { if case .cancel(let request) = $0 { request } else { nil } }
    }

    var translations: [TranslationPlanner.Effect] {
        effects.filter { if case .translation = $0 { true } else { false } }
    }

    var provisionals: [TranslationPlanner.Effect] {
        effects.filter { if case .provisional = $0 { true } else { false } }
    }
}

@Suite("翻譯排程：定稿")
struct TranslationPlannerFinalTests {
    @Test("一段確定就送出請求：模型、台灣用語的提示、場次資訊、關鍵詞、這一段的英文，以及前兩段當上下文")
    func requestContent() throws {
        var driver = PlanDriver {
            $0.model = "gpt-6-luna"
            $0.title = "Building Agents"
            $0.event = "re:Invent"
            $0.speaker = "Jane Doe"
            $0.keywords = ["AgentCore", " Karpenter ", "agentcore", ""]
        }
        driver.finish(0, "First segment.", at: 1)
        driver.finish(1, "Second segment.", at: 1.5)
        driver.finish(2, "Third segment.", at: 2)
        driver.finish(3, "With AgentCore Runtime, each session runs in isolation.", at: 2.5)

        #expect(driver.started.map(\.request) == [0, 1, 2, 3], "多段可以同時翻譯")
        let first = (try driver.content(0))
        #expect(first.model == "gpt-6-luna")
        #expect(first.reasoningEffort == "none", "即時翻譯要快")
        #expect(first.schema == nil)
        #expect(first.input.contains("First segment."))
        #expect(!first.input.contains("前文"), "第一段沒有上下文")
        for expected in ["台灣", "繁體中文", "Building Agents", "re:Invent", "Jane Doe", "AgentCore、Karpenter"] {
            #expect(first.instructions.contains(expected), "提示裡要有「\(expected)」")
        }

        let last = (try driver.content(3))
        #expect(last.input.contains("With AgentCore Runtime, each session runs in isolation."))
        #expect(last.input.contains("Second segment."))
        #expect(last.input.contains("Third segment."))
        #expect(!last.input.contains("First segment."), "只帶前兩段")
        let contextRange = try #require(last.input.range(of: "Third segment."))
        let targetRange = try #require(last.input.range(of: "With AgentCore Runtime"))
        #expect(contextRange.lowerBound < targetRange.lowerBound, "上下文在前，要翻的這一段在最後")
    }

    @Test("定稿依段的順序送出：後面的段先翻好，也要等前面的段")
    func ordered() {
        var driver = PlanDriver()
        driver.finish(0, "Zero.", at: 0)
        driver.finish(1, "One.", at: 0.5)
        driver.finish(2, "Two.", at: 1)

        #expect(driver.complete(2, "二。", at: 1.5).isEmpty)
        #expect(driver.complete(1, "一。", at: 1.6).isEmpty)
        #expect(driver.planner.hasPendingFinals)
        let flushed = driver.complete(0, " 零。\n", at: 2)
        #expect(flushed == [
            .translation(segment: 0, text: "零。"),
            .translation(segment: 1, text: "一。"),
            .translation(segment: 2, text: "二。"),
        ])
        #expect(!driver.planner.hasPendingFinals)
        #expect(driver.planner.nextDeadline == nil)
    }

    @Test("3 秒沒有任何輸出就再送一個相同的請求；先回來的為準，另一個被取消")
    func hedge() throws {
        var driver = PlanDriver()
        driver.finish(0, "Hello there.", at: 10)
        #expect(driver.planner.nextDeadline == 13)

        driver.run(driver.planner.advance(to: 12.9))
        #expect(driver.started.count == 1)
        driver.run(driver.planner.advance(to: 13))
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)) == (try driver.content(0)))
        driver.run(driver.planner.advance(to: 14))
        #expect(driver.started.count == 2, "備援只送一個")

        let done = driver.complete(1, "你好。", at: 14.2)
        #expect(done == [.cancel(request: 0), .translation(segment: 0, text: "你好。")])
        // 被取消的請求之後才回來：沒有作用
        #expect(driver.complete(0, "哈囉。", at: 15).isEmpty)
        #expect(driver.translations.count == 1)
    }

    @Test("已經開始有輸出的請求不需要備援")
    func noHedgeOnceStreaming() {
        var driver = PlanDriver()
        driver.finish(0, "Hello there.", at: 0)
        driver.run(driver.planner.progress(request: 0, text: "你", at: 2.5))
        #expect(driver.planner.nextDeadline == 8)
        driver.run(driver.planner.advance(to: 5))
        #expect(driver.started.count == 1)
        #expect(driver.translations.isEmpty, "定稿要等完整的結果才送")
        #expect(driver.complete(0, "你好。", at: 5.5) == [.translation(segment: 0, text: "你好。")])
    }

    @Test("8 秒沒有結果就放棄：那一段沒有定稿，後面的段照常送出")
    func giveUp() {
        var driver = PlanDriver()
        driver.finish(0, "Stuck.", at: 0)
        driver.finish(1, "Fine.", at: 1)
        driver.complete(1, "沒問題。", at: 2)
        #expect(driver.translations.isEmpty)

        driver.run(driver.planner.advance(to: 7.9))
        #expect(driver.translations.isEmpty)
        let gaveUp = driver.run(driver.planner.advance(to: 8))
        #expect(gaveUp == [.cancel(request: 0), .cancel(request: 2), .translation(segment: 1, text: "沒問題。")])
        #expect(!driver.planner.hasPendingFinals)
        // 放棄之後才回來的結果不再送出
        #expect(driver.complete(0, "卡住了。", at: 9).isEmpty)
    }

    @Test("請求失敗會重試；三次都失敗就沒有定稿，也不會卡住後面的段")
    func retries() {
        var driver = PlanDriver()
        driver.finish(0, "Unlucky.", at: 0)
        driver.finish(1, "Lucky.", at: 0.1)
        driver.complete(1, "幸運。", at: 0.5)

        driver.run(driver.planner.failed(request: 0, at: 0.6))
        #expect(driver.started.map(\.request) == [0, 1, 2])
        driver.run(driver.planner.failed(request: 2, at: 0.7))
        #expect(driver.started.map(\.request) == [0, 1, 2, 3])
        #expect(driver.translations.isEmpty)

        let last = driver.run(driver.planner.failed(request: 3, at: 0.8))
        #expect(last == [.translation(segment: 1, text: "幸運。")])
        #expect(driver.started.count == 4, "不再重試")
        #expect(!driver.planner.hasPendingFinals)
    }

    @Test("輸出是空的也算失敗")
    func emptyOutput() {
        var driver = PlanDriver()
        driver.finish(0, "Say something.", at: 0)
        driver.complete(0, "  \n", at: 1)
        #expect(driver.translations.isEmpty)
        #expect(driver.started.count == 2)
        #expect(driver.complete(1, "說點什麼。", at: 2) == [.translation(segment: 0, text: "說點什麼。")])
    }

    @Test("譯文出現簡體字：重試一次，並明確要求只用繁體字；重試的結果用繁體就採用")
    func simplifiedRetry() throws {
        var driver = PlanDriver()
        driver.finish(0, "This is the default server.", at: 0)
        let retried = driver.complete(0, "这是默认的服务器。", at: 1)
        #expect(driver.translations.isEmpty)
        #expect(retried.count == 1)
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)).instructions.contains("簡體"))
        #expect((try driver.content(1)).input == (try driver.content(0)).input)

        #expect(driver.complete(1, "這是預設的伺服器。", at: 2) == [.translation(segment: 0, text: "這是預設的伺服器。")])
    }

    @Test("重試之後還是簡體字，或重試失敗：採用手上有的結果，不再重試", arguments: [true, false])
    func simplifiedTwice(secondFails: Bool) {
        var driver = PlanDriver()
        driver.finish(0, "This is the default server.", at: 0)
        driver.complete(0, "这是默认的服务器。", at: 1)
        if secondFails {
            driver.run(driver.planner.failed(request: 1, at: 2))
            #expect(driver.started.count == 3, "還有一次重試的額度")
            driver.run(driver.planner.failed(request: 2, at: 2.5))
            #expect(driver.translations == [.translation(segment: 0, text: "这是默认的服务器。")])
        } else {
            driver.complete(1, "这是預設的伺服器。", at: 2)
            #expect(driver.translations == [.translation(segment: 0, text: "这是預設的伺服器。")])
        }
        #expect(!driver.planner.hasPendingFinals)
    }

    @Test("併入晚到的尾巴：還沒翻好就取消重翻；已經送出定稿就翻完再送一次")
    func extended() throws {
        var driver = PlanDriver()
        // 還沒翻好
        driver.finish(0, "we are going to the", at: 0)
        let restarted = driver.run(driver.planner.segmentExtended(0, text: "we are going to the conference.", at: 0.5))
        #expect(restarted.first == .cancel(request: 0))
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)).input.contains("we are going to the conference."))
        #expect(driver.complete(0, "我們要去", at: 0.8).isEmpty, "舊的請求已經取消")
        #expect(driver.complete(1, "我們要去參加研討會。", at: 1) == [.translation(segment: 0, text: "我們要去參加研討會。")])

        // 已經送出
        driver.finish(1, "and it starts at", at: 2)
        driver.complete(2, "而且開始的時間是", at: 2.5)
        #expect(driver.translations.count == 2)
        driver.run(driver.planner.segmentExtended(1, text: "and it starts at nine.", at: 3))
        #expect(driver.planner.hasPendingFinals)
        #expect(driver.complete(3, "而且 9 點開始。", at: 3.6) == [.translation(segment: 1, text: "而且 9 點開始。")])
        #expect(driver.translations.count == 3, "同一段送了兩次，以最後一次為準")

        // 下一段的上下文用的是併入之後的文字
        driver.finish(2, "See you there.", at: 5)
        #expect(driver.started.last?.content.input.contains("and it starts at nine.") == true)
    }
}

@Suite("翻譯排程：暫定譯文")
struct TranslationPlannerProvisionalTests {
    @Test("每多 3 個字、而且距離上一次至少 1 秒才送；同一時間只有一個請求")
    func throttle() throws {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("Today", segment: 0, at: 0.2))
        driver.run(driver.planner.pendingText("Today I", segment: 0, at: 0.4))
        #expect(driver.started.isEmpty, "還不到 3 個字")
        driver.run(driver.planner.pendingText("Today I want", segment: 0, at: 0.6))
        #expect(driver.started.count == 1)
        #expect((try driver.content(0)).input.contains("Today I want"))
        #expect((try driver.content(0)).instructions.contains("還沒說完"))

        driver.run(driver.planner.pendingText("Today I want to talk about how", segment: 0, at: 1.2))
        #expect(driver.started.count == 1, "上一個請求還沒回來")
        driver.complete(0, "今天我想", at: 1.3)
        #expect(driver.started.count == 1, "距離上一次還不到 1 秒")

        driver.run(driver.planner.pendingText("Today I want to talk about how we", segment: 0, at: 1.7))
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)).input.contains("Today I want to talk about how we"), "用的是最新的文字")
        #expect(driver.cancelled.isEmpty)
    }

    @Test("暫定譯文回來時文字又變長了，而且已經過了 1 秒：馬上用最新的文字再送一次")
    func chained() throws {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        driver.run(driver.planner.pendingText("one two three four five six seven", segment: 0, at: 0.9))
        let next = driver.complete(0, "一二三", at: 1.4)
        #expect(next.count == 2)
        #expect(next.first == .provisional(segment: 0, text: "一二三"))
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)).input.contains("one two three four five six seven"))
    }

    @Test("一段的第一個暫定譯文邊收邊送；之後的版本等完整回來才整段取代")
    func streamsOnlyFirst() {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        #expect(driver.run(driver.planner.progress(request: 0, text: "一", at: 0.5)) == [.provisional(segment: 0, text: "一")])
        #expect(driver.run(driver.planner.progress(request: 0, text: "一二", at: 0.6)) == [.provisional(segment: 0, text: "一二")])
        #expect(driver.complete(0, "一二三", at: 0.7) == [.provisional(segment: 0, text: "一二三")])

        driver.run(driver.planner.pendingText("one two three four five six", segment: 0, at: 1.5))
        #expect(driver.started.count == 2)
        #expect(driver.run(driver.planner.progress(request: 1, text: "一", at: 2)).isEmpty, "畫面上已經有字，不能先縮短再變長")
        #expect(driver.complete(1, "一二三四五六", at: 2.4) == [.provisional(segment: 0, text: "一二三四五六")])
    }

    @Test("這一段確定之後：還沒回來的暫定譯文被取消，它的結果不會送出；下一段重新計算")
    func cancelledByFinal() throws {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        let finished = driver.finish(0, "one two three four.", at: 0.5)
        #expect(finished.first == .cancel(request: 0))
        #expect(driver.complete(0, "一二三", at: 0.8).isEmpty)
        #expect(driver.provisionals.isEmpty)

        driver.run(driver.planner.pendingText("five six", segment: 1, at: 1))
        #expect(driver.started.count == 2, "下一段從 0 個字算起")
        driver.run(driver.planner.pendingText("five six seven", segment: 1, at: 1.2))
        #expect(driver.started.count == 3)
        #expect((try driver.content(2)).input.contains("one two three four."), "帶上一段當上下文")
    }

    @Test("關閉暫定譯文：不送任何暫定的請求，定稿照常")
    func disabled() {
        var driver = PlanDriver { $0.provisional = false }
        driver.run(driver.planner.pendingText("one two three four five six", segment: 0, at: 0))
        driver.run(driver.planner.pendingText("one two three four five six seven eight nine", segment: 0, at: 2))
        #expect(driver.started.isEmpty)
        driver.finish(0, "one two three four five six seven eight nine.", at: 3)
        #expect(driver.started.count == 1)
    }

    @Test("暫定譯文的請求 4 秒沒有回來就取消，之後用最新的文字重送")
    func stuck() throws {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        #expect(driver.planner.nextDeadline == 4)
        driver.run(driver.planner.pendingText("one two three four five six", segment: 0, at: 2))
        let timedOut = driver.run(driver.planner.advance(to: 4))
        #expect(timedOut.first == .cancel(request: 0))
        #expect(driver.started.count == 2)
        #expect((try driver.content(1)).input.contains("one two three four five six"))
    }

    @Test("暫定譯文的請求失敗：不影響定稿，下一次文字變長時再試")
    func provisionalFailure() {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        #expect(driver.run(driver.planner.failed(request: 0, at: 0.3)).isEmpty)
        driver.run(driver.planner.pendingText("one two three four five six", segment: 0, at: 1.1))
        #expect(driver.started.count == 2)
        driver.finish(0, "one two three four five six.", at: 2)
        #expect(driver.complete(2, "一二三四五六。", at: 3) == [.translation(segment: 0, text: "一二三四五六。")])
    }

    @Test("內容沒有變的暫定譯文不重複送出")
    func noDuplicates() {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("one two three", segment: 0, at: 0))
        #expect(driver.run(driver.planner.progress(request: 0, text: "一二", at: 0.5)) == [.provisional(segment: 0, text: "一二")])
        #expect(driver.run(driver.planner.progress(request: 0, text: "一二 ", at: 0.6)).isEmpty, "只多了空白")
        #expect(driver.run(driver.planner.progress(request: 0, text: "一二三", at: 0.7)) == [.provisional(segment: 0, text: "一二三")])
        #expect(driver.complete(0, "一二三", at: 0.8).isEmpty, "完成時的全文和剛才送出的一樣")

        // 下一段從頭算起：同樣的字也要送
        driver.finish(0, "one two three.", at: 1)
        driver.run(driver.planner.pendingText("one two three", segment: 1, at: 2))
        #expect(driver.complete(2, "一二三", at: 2.5) == [.provisional(segment: 1, text: "一二三")])
    }

    @Test("中文來源：每 2 個中文字算一個字")
    func chineseWords() {
        var driver = PlanDriver()
        driver.run(driver.planner.pendingText("今天我想", segment: 0, at: 0))
        #expect(driver.started.isEmpty)
        driver.run(driver.planner.pendingText("今天我想談談這", segment: 0, at: 0.2))
        #expect(driver.started.count == 1)
    }
}
