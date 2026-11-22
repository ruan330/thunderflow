import Foundation
import Testing
import ThunderCore
import ThunderEngines

/// 整句的暫定譯文（DESIGN.md 5.6.2 節）：整句模式時，暫定譯文翻的是「這一句目前聽到的部分」（已經確定的段＋進行中的文字），
/// 並把畫面上已經有的暫定譯文放進請求，請模型保留、只在後面接上新的部分。一句說完才結束，整句定稿照舊取代它。
private struct DraftDriver {
    var planner: TranslationPlanner
    private(set) var effects: [TranslationPlanner.Effect] = []

    init(_ configure: (inout TranslationPlanner.Configuration) -> Void = { _ in }) {
        var configuration = TranslationPlanner.Configuration()
        configuration.sentences = true
        configuration.provisional = true
        configuration.sentenceProvisional = true
        configure(&configuration)
        planner = TranslationPlanner(configuration: configuration)
    }

    @discardableResult
    mutating func run(_ new: [TranslationPlanner.Effect]) -> [TranslationPlanner.Effect] {
        effects += new
        return new
    }

    @discardableResult
    mutating func finish(_ segment: Int, _ text: String, _ reason: Segmenter.Reason, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.segmentFinished(segment, text: text, reason: reason, at: now))
    }

    @discardableResult
    mutating func pending(_ text: String, segment: Int, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.pendingText(text, segment: segment, at: now))
    }

    @discardableResult
    mutating func progress(_ request: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.progress(request: request, text: text, at: now))
    }

    @discardableResult
    mutating func complete(_ request: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.completed(request: request, text: text, at: now))
    }

    @discardableResult
    mutating func fail(_ request: Int, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.failed(request: request, at: now))
    }

    @discardableResult
    mutating func advance(to now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.advance(to: now))
    }

    @discardableResult
    mutating func flush(at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.flush(at: now))
    }

    /// 送出過的請求：編號與內容。
    var requests: [(id: Int, content: TextRequest)] {
        effects.compactMap { if case .start(let id, let content) = $0 { (id, content) } else { nil } }
    }

    /// 暫定譯文的請求（提示裡講明講者還沒說完的那一種）。
    var draftRequests: [(id: Int, content: TextRequest)] {
        requests.filter { $0.content.input.contains("這一句目前聽到的部分") }
    }

    var cancelled: [Int] {
        effects.compactMap { if case .cancel(let request) = $0 { request } else { nil } }
    }

    var drafts: [TranslationPlanner.Effect] {
        effects.filter { if case .sentenceProvisional = $0 { true } else { false } }
    }

    var segmentProvisionals: [TranslationPlanner.Effect] {
        effects.filter { if case .provisional = $0 { true } else { false } }
    }
}

@Suite("翻譯排程：整句的暫定譯文")
struct TranslationPlannerDraftTests {
    @Test("暫定譯文的請求帶這一句已經確定的段與進行中的文字；前文是最近幾句的英文與已經翻好的中文")
    func coversWholeSentence() throws {
        var driver = DraftDriver { $0.title = "Breaking LLMs" }
        driver.finish(0, "Hello world.", .sentenceEnd, at: 0)
        let sentenceRequest = try #require(driver.requests.last)
        driver.complete(sentenceRequest.id, "哈囉，世界。", at: 0.5)

        driver.finish(1, "So the first thing", .pause, at: 2)
        #expect(driver.draftRequests.isEmpty, "這一段沒有經過「進行中」就確定了，還沒有暫定譯文的請求")
        driver.pending("we did was", segment: 2, at: 3)

        let draft = try #require(driver.draftRequests.last)
        #expect(draft.content.input.hasSuffix("這一句目前聽到的部分：\nSo the first thing we did was"))
        #expect(draft.content.input.contains("英：Hello world.\n中：哈囉，世界。"), "前文是上一句的英文與中文")
        #expect(!draft.content.input.contains("畫面上的暫定譯文"), "這一句還沒有暫定譯文顯示在畫面上")
        for expected in ["還沒說完", "台灣", "繁體中文", "口語", "Breaking LLMs"] {
            #expect(draft.content.instructions.contains(expected), "暫定譯文的提示裡要有「\(expected)」")
        }
        #expect(draft.content.reasoningEffort == "none")
        #expect(driver.segmentProvisionals.isEmpty, "整句的暫定譯文取代逐段的暫定譯文")
    }

    @Test("每多 3 個字、而且距離上一次至少 1 秒才送一次；同一時間只有一個請求；畫面上的暫定譯文放進下一個請求，請模型保留")
    func cadenceAndKeep() throws {
        var driver = DraftDriver()
        driver.pending("One two", segment: 0, at: 0)
        #expect(driver.draftRequests.isEmpty, "不到 3 個字不送")
        driver.pending("One two three", segment: 0, at: 0.2)
        let first = try #require(driver.draftRequests.first)
        #expect(driver.draftRequests.count == 1)

        driver.pending("One two three four five six", segment: 0, at: 0.5)
        #expect(driver.draftRequests.count == 1, "上一個請求還沒回來，不送新的")

        #expect(driver.complete(first.id, "一二三", at: 0.9) == [.sentenceProvisional(number: 0, first: 0, text: "一二三")])
        #expect(driver.draftRequests.count == 1, "距離上一次送出還不到 1 秒")

        driver.pending("One two three four five six seven", segment: 0, at: 1.3)
        let second = try #require(driver.draftRequests.last)
        #expect(driver.draftRequests.count == 2)
        #expect(second.content.input.contains("畫面上的暫定譯文：\n一二三"))
        #expect(second.content.input.hasSuffix("這一句目前聽到的部分：\nOne two three four five six seven"))
        #expect(second.content.instructions.contains("畫面上的暫定譯文"), "提示要說明怎麼對待畫面上已經有的字")
    }

    @Test("一句中間的段結束時暫定譯文不中斷；一句說完才取消還沒回來的請求，之後的結果不採用，下一句重新開始")
    func spansSegments() throws {
        var driver = DraftDriver()
        driver.pending("So the first thing", segment: 0, at: 0)
        let a = try #require(driver.draftRequests.last)
        driver.finish(0, "So the first thing", .pause, at: 0.5)
        #expect(!driver.cancelled.contains(a.id), "一句還沒說完：段結束不取消暫定譯文")
        let segmentFinal = try #require(driver.requests.last)
        driver.complete(segmentFinal.id, "所以第一件事", at: 0.7)
        #expect(driver.complete(a.id, "所以第一件事", at: 0.8) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一件事")])

        driver.pending("we did", segment: 1, at: 1.0)
        #expect(driver.draftRequests.count == 1, "這一句只多了 2 個字")
        driver.pending("we did was this", segment: 1, at: 1.6)
        let b = try #require(driver.draftRequests.last)
        #expect(b.content.input.hasSuffix("這一句目前聽到的部分：\nSo the first thing we did was this"))
        #expect(b.content.input.contains("畫面上的暫定譯文：\n所以第一件事"))

        driver.finish(1, "we did was this.", .sentenceEnd, at: 2.0)
        #expect(driver.cancelled.contains(b.id), "一句說完：還沒回來的暫定譯文取消")
        #expect(driver.complete(b.id, "所以我們做的第一件事是這個", at: 2.2).isEmpty, "取消之後回來的結果不採用")

        driver.pending("Next one here", segment: 2, at: 3)
        let c = try #require(driver.draftRequests.last)
        #expect(c.id != b.id)
        #expect(c.content.input.hasSuffix("這一句目前聽到的部分：\nNext one here"))
        #expect(!c.content.input.contains("畫面上的暫定譯文"), "新的一句從頭開始")
        #expect(driver.complete(c.id, "下一句", at: 3.5) == [.sentenceProvisional(number: 1, first: 2, text: "下一句")])
    }

    @Test("邊收邊送：收到的字接得上畫面上的字（以它開頭）就先送出；接不上的等完整回來再整個換掉")
    func streamsOnlyAppends() throws {
        var driver = DraftDriver()
        driver.pending("So the first thing", segment: 0, at: 0)
        let a = try #require(driver.draftRequests.last)
        #expect(driver.progress(a.id, "所以", at: 0.3) == [.sentenceProvisional(number: 0, first: 0, text: "所以")])
        #expect(driver.progress(a.id, "所以第一", at: 0.4) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一")])
        #expect(driver.complete(a.id, "所以第一件事", at: 0.6) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一件事")])

        driver.pending("So the first thing we did was", segment: 0, at: 1.2)
        let b = try #require(driver.draftRequests.last)
        #expect(driver.progress(b.id, "所以第一件", at: 1.4).isEmpty, "還在重打畫面上已經有的字")
        #expect(driver.progress(b.id, "所以第一件事是", at: 1.5) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一件事是")])
        #expect(driver.progress(b.id, "所以第一件事是我們", at: 1.6) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一件事是我們")])
        #expect(driver.complete(b.id, "所以第一件事是我們做的", at: 1.8) == [.sentenceProvisional(number: 0, first: 0, text: "所以第一件事是我們做的")])

        driver.pending("So the first thing we did was this one right", segment: 0, at: 2.4)
        let c = try #require(driver.draftRequests.last)
        #expect(driver.progress(c.id, "我們做的第一件事", at: 2.6).isEmpty, "接不上畫面上的字：先不換")
        #expect(
            driver.complete(c.id, "我們做的第一件事是這個", at: 2.9)
                == [.sentenceProvisional(number: 0, first: 0, text: "我們做的第一件事是這個")], "完整回來才換掉")
    }

    @Test("請求超過時限沒有回來就取消，字夠多時再送新的；失敗的請求不影響下一次")
    func timeoutAndFailure() throws {
        var driver = DraftDriver { $0.provisionalTimeout = 4 }
        driver.pending("One two three", segment: 0, at: 0)
        let a = try #require(driver.draftRequests.last)
        #expect(driver.planner.nextDeadline == 4)

        driver.pending("One two three four five six", segment: 0, at: 4.5)
        #expect(driver.cancelled.contains(a.id), "超過 4 秒沒有回來")
        let b = try #require(driver.draftRequests.last)
        #expect(b.id != a.id, "字夠多：馬上送新的")

        driver.fail(b.id, at: 5)
        driver.pending("One two three four five six seven eight nine", segment: 0, at: 6)
        #expect(driver.draftRequests.count == 3, "失敗之後，字夠多時照常送")
    }

    @Test("收尾時這一句當成說完：取消還沒回來的暫定譯文")
    func flushCancels() throws {
        var driver = DraftDriver()
        driver.pending("One two three", segment: 0, at: 0)
        let a = try #require(driver.draftRequests.last)
        driver.finish(0, "One two three", .flush, at: 0.5)
        driver.flush(at: 0.5)
        #expect(driver.cancelled.contains(a.id))
        #expect(driver.complete(a.id, "一二三", at: 0.8).isEmpty)
    }

    @Test("每一句的第一個暫定譯文可以提早送（sentenceProvisionalFirstWords 個字就送）；之後照每多 3 個字、至少隔 1 秒")
    func earlyFirstRequest() throws {
        var driver = DraftDriver { $0.sentenceProvisionalFirstWords = 2 }
        driver.pending("One", segment: 0, at: 0)
        #expect(driver.draftRequests.isEmpty)
        driver.pending("One two", segment: 0, at: 0.3)
        let first = try #require(driver.draftRequests.first, "2 個字就送出這一句的第一個暫定譯文")
        driver.complete(first.id, "一二", at: 0.8)
        driver.pending("One two three four", segment: 0, at: 1.4)
        #expect(driver.draftRequests.count == 1, "之後要多 3 個字")
        driver.pending("One two three four five", segment: 0, at: 1.5)
        #expect(driver.draftRequests.count == 2)

        // 下一句的第一個也一樣提早
        driver.finish(0, "One two three four five.", .sentenceEnd, at: 2)
        driver.pending("Six seven", segment: 1, at: 2.5)
        #expect(driver.draftRequests.last?.content.input.hasSuffix("這一句目前聽到的部分：\nSix seven") == true)
    }

    @Test("前文裡還沒翻好的句子不放進暫定譯文的請求（模型會把它也翻進這一句）；翻好之後才帶上")
    func contextOnlyTranslated() throws {
        var driver = DraftDriver()
        driver.finish(0, "So this model has no memory.", .sentenceEnd, at: 0)
        let sentenceRequest = try #require(driver.requests.last)
        driver.pending("In order", segment: 1, at: 0.3)
        driver.pending("In order to create", segment: 1, at: 0.4)
        let early = try #require(driver.draftRequests.last)
        #expect(!early.content.input.contains("So this model has no memory."), "上一句的整句定稿還沒回來：不帶它的英文")
        #expect(!early.content.input.contains("前文"))

        driver.complete(sentenceRequest.id, "這個模型沒有記憶。", at: 0.9)
        driver.complete(early.id, "為了營造", at: 1.0)
        driver.pending("In order to create the illusion of", segment: 1, at: 1.6)
        let later = try #require(driver.draftRequests.last)
        #expect(later.id != early.id)
        #expect(later.content.input.contains("英：So this model has no memory.\n中：這個模型沒有記憶。"), "翻好之後帶上")
    }

    @Test("暫定譯文出現原文沒有的英文字（模型的雜訊）時不採用；原文裡有的名稱照常")
    func rejectsStrayEnglish() throws {
        var driver = DraftDriver { $0.keywords = ["AgentCore"] }
        driver.pending("I worked at Microsoft on", segment: 0, at: 0)
        let a = try #require(driver.draftRequests.last)
        #expect(driver.progress(a.id, "我曾在 Microsoft", at: 0.2) == [.sentenceProvisional(number: 0, first: 0, text: "我曾在 Microsoft")])
        #expect(driver.complete(a.id, "我曾在 Microsoft 負責，無 guess end. Need render", at: 0.5).isEmpty, "不採用有雜訊的版本")

        driver.pending("I worked at Microsoft on AgentCore and then", segment: 0, at: 1.2)
        let b = try #require(driver.draftRequests.last)
        #expect(b.content.input.contains("畫面上的暫定譯文：\n我曾在 Microsoft"), "畫面上仍然是上一個好的版本")
        #expect(
            driver.complete(b.id, "我曾在 Microsoft 負責 AgentCore", at: 1.6)
                == [.sentenceProvisional(number: 0, first: 0, text: "我曾在 Microsoft 負責 AgentCore")])
    }

    @Test("沒有開暫定譯文時，整句的暫定譯文也不送")
    func respectsProvisionalSwitch() {
        var driver = DraftDriver { $0.provisional = false }
        driver.pending("One two three four", segment: 0, at: 0)
        #expect(driver.draftRequests.isEmpty)
        #expect(driver.drafts.isEmpty)
    }
}
