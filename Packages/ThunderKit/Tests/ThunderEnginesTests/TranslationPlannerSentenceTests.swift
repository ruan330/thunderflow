import Foundation
import Testing
import ThunderCore
import ThunderEngines

/// 整句模式的翻譯排程（DESIGN.md 5.6.2 節）：段照樣先翻，一句說完再把整句重翻一次，取代這一句各段的定稿。
/// 暫定譯文預設關掉，讓請求的編號只來自定稿（暫定譯文另有測試）。
private struct SentenceDriver {
    var planner: TranslationPlanner
    private(set) var effects: [TranslationPlanner.Effect] = []

    init(_ configure: (inout TranslationPlanner.Configuration) -> Void = { _ in }) {
        var configuration = TranslationPlanner.Configuration()
        configuration.sentences = true
        configuration.provisional = false
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
    mutating func amend(_ segment: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.segmentAmended(segment, text: text, at: now))
    }

    @discardableResult
    mutating func extend(_ segment: Int, _ text: String, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.segmentExtended(segment, text: text, at: now))
    }

    @discardableResult
    mutating func pending(_ text: String, segment: Int, at now: TimeInterval) -> [TranslationPlanner.Effect] {
        run(planner.pendingText(text, segment: segment, at: now))
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

    var started: [Int] {
        effects.compactMap { if case .start(let request, _) = $0 { request } else { nil } }
    }

    /// 第 `request` 個請求的內容。還沒有送出這個請求就讓測試失敗（而不是當掉）。
    func content(_ request: Int) throws -> TextRequest {
        let found = effects.compactMap { if case .start(let id, let content) = $0, id == request { content } else { nil } }
        return try #require(found.first, "還沒有送出第 \(request) 個請求")
    }

    var cancelled: [Int] {
        effects.compactMap { if case .cancel(let request) = $0 { request } else { nil } }
    }

    var translations: [TranslationPlanner.Effect] {
        effects.filter { if case .translation = $0 { true } else { false } }
    }

    var sentences: [TranslationPlanner.Effect] {
        effects.filter { if case .sentence = $0 { true } else { false } }
    }
}

private func starts(_ effects: [TranslationPlanner.Effect]) -> [Int] {
    effects.compactMap { if case .start(let request, _) = $0 { request } else { nil } }
}

@Suite("翻譯排程：整句模式")
struct TranslationPlannerSentenceTests {
    @Test("一句的最後一段確定時，另外送出整句的請求；結果以整句定稿送出，最後一段自己的定稿不送出")
    func sentenceRequest() throws {
        var driver = SentenceDriver { $0.title = "Breaking LLMs" }
        driver.finish(0, "And the reason for that is", .pause, at: 0)
        driver.finish(1, "that it never occurred.", .sentenceEnd, at: 1)
        #expect(driver.started == [0, 1, 2], "兩段各一個請求，再加上整句的請求")

        let sentence = try driver.content(2)
        #expect(sentence.input.hasSuffix("這一句：\nAnd the reason for that is that it never occurred."))
        #expect(!sentence.input.contains("前文"), "第一句沒有前文")
        for expected in ["通順", "口語", "you know", "台灣", "繁體中文", "Breaking LLMs"] {
            #expect(sentence.instructions.contains(expected), "整句的提示裡要有「\(expected)」")
        }
        #expect(sentence.reasoningEffort == "none")
        #expect(try driver.content(0).input.contains("這一段"), "段的請求照舊")

        #expect(driver.complete(0, "原因是", at: 1.2) == [.translation(segment: 0, text: "原因是")])
        #expect(driver.complete(1, "它從來沒有出現過。", at: 1.5).isEmpty, "最後一段自己的定稿只留著備用")
        #expect(driver.planner.hasPendingFinals)
        #expect(
            driver.complete(2, "原因是它從來沒有出現過。", at: 1.9)
                == [.sentence(number: 0, first: 0, last: 1, text: "原因是它從來沒有出現過。")])
        #expect(!driver.planner.hasPendingFinals)
        #expect(driver.planner.nextDeadline == nil)
    }

    @Test("一句只有一段：只送出整句定稿；整句定稿先到時，這一段還沒回來的請求被取消")
    func singleSegmentSentence() {
        var driver = SentenceDriver()
        driver.finish(0, "Hello world.", .sentenceEnd, at: 0)
        #expect(driver.started == [0, 1])
        #expect(
            driver.complete(1, "哈囉，世界。", at: 0.9)
                == [.cancel(request: 0), .sentence(number: 0, first: 0, last: 0, text: "哈囉，世界。")])
        #expect(driver.complete(0, "哈囉世界", at: 1).isEmpty, "被取消的請求的結果不採用")
        #expect(driver.translations.isEmpty)
        #expect(!driver.planner.hasPendingFinals)
    }

    @Test("定稿依段的順序送出：下一句的段要等前一句的整句定稿")
    func ordered() {
        var driver = SentenceDriver()
        driver.finish(0, "First sentence.", .sentenceEnd, at: 0)
        driver.finish(1, "And then", .pause, at: 1)
        #expect(driver.started == [0, 1, 2])

        #expect(driver.complete(2, "然後", at: 1.5).isEmpty, "要等前一句")
        #expect(
            driver.complete(1, "第一句。", at: 1.6) == [
                .cancel(request: 0),
                .sentence(number: 0, first: 0, last: 0, text: "第一句。"),
                .translation(segment: 1, text: "然後"),
            ])
    }

    @Test("整句定稿先到：這一句還沒送出的段直接被取代（請求取消），不必等它們")
    func sentenceSupersedesPendingSegments() {
        var driver = SentenceDriver()
        driver.finish(0, "When you ask the next", .pause, at: 0)
        driver.finish(1, "question.", .sentenceEnd, at: 0.5)
        #expect(driver.started == [0, 1, 2])
        #expect(
            driver.complete(2, "你提出下一個問題時。", at: 1)
                == [.cancel(request: 0), .cancel(request: 1), .sentence(number: 0, first: 0, last: 1, text: "你提出下一個問題時。")])
        #expect(driver.translations.isEmpty)
        #expect(!driver.planner.hasPendingFinals)
    }

    @Test("整句的請求帶前三句的英文與已經翻好的中文，依順序；前一句還沒翻好時只帶英文")
    func context() throws {
        var driver = SentenceDriver()
        let english = ["One.", "Two.", "Three.", "Four.", "Five."]
        for (index, text) in english.enumerated() {
            let time = Double(index)
            driver.finish(index, text, .sentenceEnd, at: time)
            driver.complete(2 * index + 1, "第\(index)句。", at: time + 0.5)
        }
        let last = try driver.content(9)
        #expect(!last.input.contains("One."), "只帶前三句")
        let lines = ["英：Two.\n中：第1句。", "英：Three.\n中：第2句。", "英：Four.\n中：第3句。", "這一句：\nFive."]
        let positions = try lines.map { try #require(last.input.range(of: $0)?.lowerBound, "要有「\($0)」") }
        #expect(positions == positions.sorted(), "前文依順序，要翻的這一句在最後")
        #expect(last.input.hasPrefix("前文（只供參考，不要翻譯）："))

        var quick = SentenceDriver()
        quick.finish(0, "One.", .sentenceEnd, at: 0)
        quick.finish(1, "Two.", .sentenceEnd, at: 0.5)
        let second = try quick.content(3)
        #expect(second.input.contains("英：One."))
        #expect(!second.input.contains("中："), "前一句還沒翻好")
    }

    @Test("整句的請求三次都失敗：改用這幾段各自的定稿接起來；全部都失敗時沒有定稿，也不會卡住下一句")
    func fallback() {
        var driver = SentenceDriver()
        driver.finish(0, "Part one", .pause, at: 0)
        driver.finish(1, "part two.", .sentenceEnd, at: 1)
        #expect(driver.complete(0, "第一部分", at: 1.2) == [.translation(segment: 0, text: "第一部分")])
        #expect(driver.complete(1, "第二部分。", at: 1.3).isEmpty)
        #expect(starts(driver.fail(2, at: 1.5)) == [3], "失敗會重試")
        #expect(starts(driver.fail(3, at: 1.6)) == [4])
        #expect(driver.fail(4, at: 1.7) == [.sentence(number: 0, first: 0, last: 1, text: "第一部分第二部分。")])

        var down = SentenceDriver()
        down.finish(0, "Hello.", .sentenceEnd, at: 0)
        let gaveUp = down.advance(to: 8.1)
        #expect(gaveUp.allSatisfy { if case .sentence = $0 { false } else if case .translation = $0 { false } else { true } })
        #expect(!down.planner.hasPendingFinals)
        down.finish(1, "Next.", .sentenceEnd, at: 9)
        #expect(
            down.complete(3, "下一句。", at: 9.5)
                == [.cancel(request: 2), .sentence(number: 1, first: 1, last: 1, text: "下一句。")])
    }

    @Test("晚到的句號讓一句在這一段結束：送出整句的請求，下一段屬於下一句")
    func lateFullStop() throws {
        var driver = SentenceDriver()
        driver.finish(0, "And the reason", .pause, at: 0)
        #expect(driver.planner.openSentence == 0)
        #expect(driver.planner.sentence(of: 0) == 0)

        #expect(starts(driver.amend(0, "And the reason.", at: 0.8)) == [1])
        #expect(try driver.content(1).input.hasSuffix("這一句：\nAnd the reason."))
        #expect(driver.planner.openSentence == 1)
        #expect(driver.planner.sentence(of: 0) == 0)

        driver.finish(1, "Next one.", .sentenceEnd, at: 2)
        #expect(driver.planner.sentence(of: 1) == 1)
        #expect(driver.amend(1, "Next one!", at: 2.2).isEmpty, "已經結束的一句補上標點不用重翻")
    }

    @Test("併入晚到的尾巴：這一句結束，用併入之後的英文翻整句；已經送出整句定稿的，翻完再送一次")
    func lateTail() throws {
        var driver = SentenceDriver()
        driver.finish(0, "We can make sure", .pause, at: 0)
        #expect(starts(driver.extend(0, "We can make sure it works.", at: 0.9)) == [1, 2])
        #expect(driver.cancelled == [0])
        #expect(try driver.content(2).input.hasSuffix("這一句：\nWe can make sure it works."))
        #expect(
            driver.complete(2, "我們可以確保它能運作。", at: 1.5)
                == [.cancel(request: 1), .sentence(number: 0, first: 0, last: 0, text: "我們可以確保它能運作。")])

        driver.finish(1, "It ran", .pause, at: 3)
        driver.amend(1, "It ran.", at: 3.5)
        #expect(driver.started.suffix(2) == [3, 4])
        #expect(driver.complete(4, "它跑了。", at: 4) == [.cancel(request: 3), .sentence(number: 1, first: 1, last: 1, text: "它跑了。")])
        #expect(starts(driver.extend(1, "It ran fast.", at: 4.5)) == [5, 6])
        #expect(try driver.content(6).input.hasSuffix("這一句：\nIt ran fast."))
        #expect(
            driver.complete(6, "它跑得很快。", at: 5)
                == [.cancel(request: 5), .sentence(number: 1, first: 1, last: 1, text: "它跑得很快。")])
    }

    @Test("講者停下來：一句的最後一段確定之後 2.5 秒都沒有新的字，這一句就算說完了；有新的字進來就重新計時")
    func speakerStops() throws {
        var driver = SentenceDriver()
        driver.finish(0, "So we", .pause, at: 0)
        #expect(driver.planner.nextDeadline == 2.5)
        #expect(driver.complete(0, "所以我們", at: 0.5) == [.translation(segment: 0, text: "所以我們")])
        driver.pending(" then", segment: 1, at: 2)
        #expect(driver.advance(to: 4.4).isEmpty)
        #expect(starts(driver.advance(to: 4.6)) == [1])
        #expect(try driver.content(1).input.hasSuffix("這一句：\nSo we"))
        #expect(driver.planner.openSentence == 1)
        #expect(driver.complete(1, "所以我們", at: 5) == [.sentence(number: 0, first: 0, last: 0, text: "所以我們")])
    }

    @Test("因為太久沒有新的字（idle）或收尾（flush）而確定的段也結束一句；一句超過 60 個字還沒有句號，也在這一段結束")
    func otherSentenceEnds() {
        var driver = SentenceDriver()
        driver.finish(0, "um so", .idle, at: 0)
        #expect(driver.started.count == 2)
        driver.finish(1, "and", .flush, at: 0.5)
        #expect(driver.started.count == 4)
        let long = Array(repeating: "word", count: 61).joined(separator: " ")
        driver.finish(2, long, .tooLong, at: 1)
        #expect(driver.started.count == 6)
        // 都在 3 秒內：還沒有輸出的請求不會先送出備援請求
        driver.finish(3, "short part", .tooLong, at: 1.5)
        #expect(driver.started.count == 7, "還沒到 60 個字")
        #expect(driver.planner.openSentence == 3)
    }

    @Test("收尾：正在說的那一句當成說完了，送出整句的請求；沒有正在說的句子時什麼都不做")
    func flush() {
        var driver = SentenceDriver()
        driver.finish(0, "So we", .pause, at: 0)
        #expect(starts(driver.flush(at: 0.5)) == [1])
        #expect(driver.flush(at: 0.6).isEmpty)
    }

    @Test("整句的譯文出現簡體字：重試一次，並明確要求只用繁體字")
    func simplified() throws {
        var driver = SentenceDriver()
        driver.finish(0, "Hello.", .sentenceEnd, at: 0)
        #expect(starts(driver.complete(1, "这是简体。", at: 0.5)) == [2])
        let retry = try driver.content(2)
        #expect(retry.instructions.contains("只能使用繁體字"))
        #expect(retry.input == (try driver.content(1)).input)
        #expect(
            driver.complete(2, "這是繁體。", at: 1)
                == [.cancel(request: 0), .sentence(number: 0, first: 0, last: 0, text: "這是繁體。")])
    }

    @Test("整句定稿還在等：hasPendingFinals 是 true；3 秒沒有任何輸出就再送一個相同的請求，先回來的為準")
    func hedge() throws {
        var driver = SentenceDriver()
        driver.finish(0, "Hello.", .sentenceEnd, at: 0)
        #expect(driver.complete(0, "哈囉。", at: 0.4).isEmpty)
        #expect(driver.planner.hasPendingFinals)
        #expect(driver.planner.nextDeadline == 3)
        #expect(starts(driver.advance(to: 3)) == [2])
        #expect(try driver.content(2).input == (try driver.content(1)).input)
        #expect(driver.complete(2, "哈囉。", at: 3.5) == [.cancel(request: 1), .sentence(number: 0, first: 0, last: 0, text: "哈囉。")])
    }

    @Test("不是整句模式：沒有句子的編號，也不會有整句的請求")
    func segmentMode() {
        var planner = TranslationPlanner()
        let effects = planner.segmentFinished(0, text: "Hello.", reason: .sentenceEnd, at: 0)
        #expect(starts(effects) == [0])
        #expect(planner.sentence(of: 0) == nil)
        #expect(planner.flush(at: 1).isEmpty)
    }
}
