import Foundation
import Testing
import ThunderEngines
import ThunderTestKit

private typealias Output = Segmenter.Output

/// 餵給切段的一步：收到文字、偵測到停頓、時間前進、收尾。
enum SegmenterStep {
    case text(String, at: TimeInterval)
    case pause(speechEnd: TimeInterval, at: TimeInterval)
    case advance(to: TimeInterval)
    case flush(at: TimeInterval)
}

extension Segmenter {
    /// 依序執行每一步，把輸出接起來。
    mutating func run(_ steps: [SegmenterStep]) -> [Segmenter.Output] {
        steps.flatMap { step -> [Segmenter.Output] in
            switch step {
            case .text(let text, let at): receive(text, at: at)
            case .pause(let speechEnd, let at): pauseDetected(speechEnd: speechEnd, at: at)
            case .advance(let to): advance(to: to)
            case .flush(let at): flush(at: at)
            }
        }
    }
}

/// 一個字一個增量、每 0.2 秒一個，從 `start` 開始。回傳步驟與最後一個字的時間。
private func words(_ text: String, from start: TimeInterval, every interval: TimeInterval = 0.2) -> [SegmenterStep] {
    text.split(separator: " ").enumerated().map { index, word in
        .text(" " + word, at: start + Double(index) * interval)
    }
}

private func finished(_ outputs: [Output]) -> [Output] {
    outputs.filter {
        if case .finished = $0 { true } else { false }
    }
}

private func close(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

@Suite("Segmenter：句號")
struct SegmenterSentenceTests {
    @Test("句號後面接著下一句的字：上一段確定，新的一段從下一個字開始")
    func periodFollowedByTheNextWord() {
        var segmenter = Segmenter()
        #expect(segmenter.receive(" Hello", at: 1.0) == [.delta(segment: 0, text: " Hello")])
        #expect(segmenter.receive(" world", at: 1.2) == [.delta(segment: 0, text: " world")])
        #expect(segmenter.receive(".", at: 1.21) == [.delta(segment: 0, text: ".")])
        #expect(
            segmenter.receive(" Next", at: 1.3) == [
                .finished(segment: 0, text: "Hello world.", reason: .sentenceEnd),
                .delta(segment: 1, text: " Next"),
            ])
    }

    @Test("句號之後 0.2 秒沒有別的字，也算一句結束")
    func periodConfirmedByQuiet() {
        var segmenter = Segmenter()
        _ = segmenter.run([.text(" Hello", at: 1.0), .text(" world", at: 1.2), .text(".", at: 1.21)])

        #expect(close(segmenter.nextDeadline, 1.41))
        #expect(segmenter.advance(to: 1.40) == [])
        #expect(segmenter.advance(to: 1.42) == [.finished(segment: 0, text: "Hello world.", reason: .sentenceEnd)])
        #expect(segmenter.receive(" Next", at: 1.9) == [.delta(segment: 1, text: " Next")])
    }

    @Test("沒有人呼叫 advance 也一樣：下一次輸入會先處理到期的計時")
    func inputsFireDueTimersFirst() {
        var segmenter = Segmenter()
        _ = segmenter.run([.text(" Hello", at: 1.0), .text(".", at: 1.1)])

        #expect(
            segmenter.receive(" Next", at: 5.0) == [
                .finished(segment: 0, text: "Hello.", reason: .sentenceEnd),
                .delta(segment: 1, text: " Next"),
            ])
    }

    @Test("句號和下一個字在同一個增量裡：拆成兩段")
    func periodAndNextWordInOneDelta() {
        var segmenter = Segmenter()
        _ = segmenter.receive(" Hello", at: 1.0)

        #expect(
            segmenter.receive(". And", at: 1.1) == [
                .delta(segment: 0, text: "."),
                .finished(segment: 0, text: "Hello.", reason: .sentenceEnd),
                .delta(segment: 1, text: " And"),
            ])
    }

    @Test("問號與驚嘆號也是句子的結尾", arguments: ["?", "!"])
    func otherTerminators(mark: String) {
        var segmenter = Segmenter()
        let outputs = segmenter.run([.text(" Really", at: 1.0), .text(mark, at: 1.01), .text(" Yes", at: 1.1)])

        #expect(finished(outputs) == [.finished(segment: 0, text: "Really" + mark, reason: .sentenceEnd)])
    }

    @Test("小數點不是句號")
    func decimalPoint() {
        var segmenter = Segmenter()
        let outputs = segmenter.run([
            .text(" more", at: 1.0), .text(" than", at: 1.2), .text(" 1", at: 1.4), .text(".", at: 1.41), .text("5", at: 1.42),
            .text(" billion", at: 1.6), .flush(at: 1.7),
        ])

        #expect(finished(outputs) == [.finished(segment: 0, text: "more than 1.5 billion", reason: .flush)])
    }

    @Test(
        "縮寫後面的句點不是句號",
        arguments: [
            (" Dr|.| Smith| is| here|.", "Dr. Smith is here."),
            (" the| U|.|S|.| market| grew|.", "the U.S. market grew."),
            (" e|.|g|.| this| one|.", "e.g. this one."),
            (" Mr|.| and| Mrs|.| Lin| agree|.", "Mr. and Mrs. Lin agree."),
        ])
    func abbreviations(pieces: String, sentence: String) {
        var segmenter = Segmenter()
        var outputs: [Output] = []
        for (index, piece) in pieces.split(separator: "|", omittingEmptySubsequences: false).enumerated() {
            outputs += segmenter.receive(String(piece), at: 1.0 + Double(index) * 0.05)
        }
        outputs += segmenter.advance(to: 10)

        #expect(finished(outputs) == [.finished(segment: 0, text: sentence, reason: .sentenceEnd)])
    }

    @Test("引號跟在句號後面，仍然屬於這一句")
    func closingQuoteAfterPeriod() {
        var segmenter = Segmenter()
        let outputs = segmenter.run([
            .text(" He", at: 1.0), .text(" said", at: 1.2), .text(" \"", at: 1.4), .text("Yes", at: 1.41), .text(".", at: 1.42),
            .text("\"", at: 1.43), .text(" Then", at: 1.6),
        ])

        #expect(finished(outputs) == [.finished(segment: 0, text: "He said \"Yes.\"", reason: .sentenceEnd)])
        #expect(outputs.last == .delta(segment: 1, text: " Then"))
    }

    @Test("中文的句號一出現就算一句結束，不用等")
    func chineseTerminators() {
        var segmenter = Segmenter()
        #expect(segmenter.receive("好", at: 1.0) == [.delta(segment: 0, text: "好")])
        #expect(
            segmenter.receive("。那", at: 1.1) == [
                .delta(segment: 0, text: "。"),
                .finished(segment: 0, text: "好。", reason: .sentenceEnd),
                .delta(segment: 1, text: "那"),
            ])
        #expect(
            segmenter.receive("我們繼續？", at: 1.2) == [
                .delta(segment: 1, text: "我們繼續？"),
                .finished(segment: 1, text: "那我們繼續？", reason: .sentenceEnd),
            ])
        #expect(segmenter.nextDeadline == nil)
    }
}

@Suite("Segmenter：停頓")
struct SegmenterPauseTests {
    private static let sixWords = words("We need to work with partners", from: 4.0)  // 最後一個字在 5.0 秒

    @Test("聲音停了，文字也安靜了 0.35 秒：這一段確定")
    func pauseThenQuietText() {
        var segmenter = Segmenter()
        _ = segmenter.run(Self.sixWords)

        #expect(segmenter.pauseDetected(speechEnd: 4.9, at: 5.2) == [])
        #expect(close(segmenter.nextDeadline, 5.35))
        #expect(segmenter.advance(to: 5.34) == [])
        #expect(
            segmenter.advance(to: 5.36) == [.finished(segment: 0, text: "We need to work with partners", reason: .pause)])
        #expect(segmenter.pendingText == "")
    }

    @Test("聲音停了但字還在來：等最後一個字之後安靜 0.35 秒才切，晚到的字算在這一段")
    func waitsForLateWords() {
        var segmenter = Segmenter()
        _ = segmenter.run(Self.sixWords)
        _ = segmenter.run([.pause(speechEnd: 4.9, at: 5.2), .text(" like", at: 5.3), .text(" AWS", at: 5.5)])

        #expect(segmenter.advance(to: 5.8) == [])
        #expect(close(segmenter.nextDeadline, 5.85))
        #expect(
            segmenter.advance(to: 5.86) == [
                .finished(segment: 0, text: "We need to work with partners like AWS", reason: .pause)
            ])
    }

    @Test("偵測到停頓時字還沒到：字到了、安靜了再切")
    func pauseBeforeAnyText() {
        var segmenter = Segmenter()
        #expect(segmenter.pauseDetected(speechEnd: 4.9, at: 5.2) == [])
        #expect(segmenter.nextDeadline == nil)
        _ = segmenter.run([.text(" late", at: 5.3), .text(" words", at: 5.4), .text(" arrive", at: 5.5)])

        #expect(segmenter.advance(to: 5.84) == [])
        #expect(segmenter.advance(to: 5.86) == [.finished(segment: 0, text: "late words arrive", reason: .pause)])
    }

    @Test("文字早就安靜了才偵測到停頓：偵測到的當下就切")
    func textAlreadyQuietWhenThePauseIsDetected() {
        var segmenter = Segmenter()
        _ = segmenter.run(Self.sixWords)

        #expect(
            segmenter.pauseDetected(speechEnd: 5.4, at: 5.7) == [
                .finished(segment: 0, text: "We need to work with partners", reason: .pause)
            ])
    }

    @Test("停頓之後字一直來、沒有安靜下來：放棄這次停頓，不切")
    func givesUpWhenTextNeverGoesQuiet() {
        var segmenter = Segmenter()
        _ = segmenter.run(Self.sixWords)
        var outputs = segmenter.pauseDetected(speechEnd: 4.9, at: 5.2)
        // 每 0.25 秒一個字，一直到 8.05 秒（講者其實沒有停）
        for index in 0..<12 { outputs += segmenter.receive(" w\(index)", at: 5.3 + Double(index) * 0.25) }

        #expect(finished(outputs).isEmpty)
        // 停頓開始已經超過 1.5 秒：就算現在安靜了，也不算那一次停頓
        #expect(segmenter.advance(to: 8.7) == [])
        // 只剩「太久沒有新的字」這個計時
        #expect(close(segmenter.nextDeadline, 10.05))
    }

    @Test("不到 3 個字不切，併到後面")
    func tooFewWordsAtAPause() {
        var segmenter = Segmenter()
        var outputs = segmenter.run([.text(" So", at: 4.0), .pause(speechEnd: 3.9, at: 4.2), .advance(to: 4.7)])
        #expect(outputs == [.delta(segment: 0, text: " So")])

        outputs = segmenter.run(
            words("we can start", from: 5.0) + [.pause(speechEnd: 5.3, at: 5.6), .advance(to: 6.01)])
        #expect(finished(outputs) == [.finished(segment: 0, text: "So we can start", reason: .pause)])
    }

    @Test("中文沒有空白：每 2 個字算一個字")
    func chineseLength() {
        var short = Segmenter()
        let none = short.run([.text("好的", at: 1.0), .pause(speechEnd: 1.0, at: 1.3), .advance(to: 1.7)])
        #expect(finished(none).isEmpty)

        var long = Segmenter()
        let some = long.run([.text("我們先看整體架構", at: 1.0), .pause(speechEnd: 1.0, at: 1.3), .advance(to: 1.7)])
        #expect(finished(some) == [.finished(segment: 0, text: "我們先看整體架構", reason: .pause)])
    }

    @Test("停頓只切一次：之後的字屬於下一段")
    func pauseAppliesOnce() {
        var segmenter = Segmenter()
        _ = segmenter.run(Self.sixWords + [.pause(speechEnd: 4.9, at: 5.2), .advance(to: 5.61)])
        let outputs = segmenter.run(words("to bring that to you", from: 6.0) + [.advance(to: 7.5)])

        // 沒有新的停頓，所以還沒確定
        #expect(finished(outputs).isEmpty)
        #expect(segmenter.pendingText == "to bring that to you")
    }
}

@Suite("Segmenter：晚到的標點")
struct SegmenterAmendTests {
    private func afterPause() -> Segmenter {
        var segmenter = Segmenter()
        _ = segmenter.run(
            words("in an environment which is secure", from: 4.0) + [.pause(speechEnd: 4.9, at: 5.2), .advance(to: 5.61)])
        return segmenter
    }

    @Test("一段確定之後才到的逗號，補在上一段後面")
    func lateComma() {
        var segmenter = afterPause()
        #expect(segmenter.receive(",", at: 5.8) == [.amended(segment: 0, text: "in an environment which is secure,")])
        #expect(segmenter.receive(" which", at: 5.9) == [.delta(segment: 1, text: " which")])
    }

    @Test("晚到的句號和下一句的第一個字在同一個增量裡：句號補在上一段，字屬於新的一段")
    func latePeriodWithTheNextWord() {
        var segmenter = afterPause()
        #expect(
            segmenter.receive(". So", at: 5.8) == [
                .amended(segment: 0, text: "in an environment which is secure."),
                .delta(segment: 1, text: " So"),
            ])
        // 補上的句號不會讓新的一段變成「等確認的句子」
        #expect(segmenter.advance(to: 6.5) == [])
    }

    @Test("最前面沒有上一段可以補：開頭的標點直接略過")
    func leadingPunctuationWithNothingBefore() {
        var segmenter = Segmenter()
        #expect(segmenter.receive(".", at: 1.0) == [])
        #expect(segmenter.receive(" Hi", at: 1.1) == [.delta(segment: 0, text: " Hi")])
    }

    @Test("因為句號而確定的段，之後才到的引號也補得上")
    func lateClosingQuote() {
        var segmenter = Segmenter()
        _ = segmenter.run([.text(" \u{201C}Yes", at: 1.0), .text(".", at: 1.1), .advance(to: 1.5)])

        #expect(segmenter.receive("\u{201D}", at: 1.6) == [.amended(segment: 0, text: "\u{201C}Yes.\u{201D}")])
    }
}

@Suite("Segmenter：晚到的尾巴")
struct SegmenterLateTailTests {
    /// 「Good morning everyone and welcome to the」在 3.2 秒收到最後一個字，講者在 3.44 秒停下來，
    /// 3.74 秒偵測到停頓並切段。句子的最後一個字 conference 還沒到。
    private func cutBeforeTheLastWord() throws -> Segmenter {
        var segmenter = Segmenter()
        let outputs = segmenter.run(
            words("Good morning everyone and welcome to the", from: 2.0) + [.pause(speechEnd: 3.44, at: 3.74)])
        try #require(
            outputs.last == .finished(segment: 0, text: "Good morning everyone and welcome to the", reason: .pause))
        return segmenter
    }

    @Test("停頓前的最後一個字連同句號晚到：併回剛確定的那一段，下一段的段號不變")
    func lateLastWordIsMergedBack() throws {
        var segmenter = try cutBeforeTheLastWord()
        #expect(segmenter.receive(" conference", at: 4.0) == [.delta(segment: 1, text: " conference")])
        #expect(segmenter.receive(".", at: 4.02) == [.delta(segment: 1, text: ".")])

        #expect(
            segmenter.receive(" Today", at: 4.1) == [
                .extended(segment: 0, text: "Good morning everyone and welcome to the conference."),
                .delta(segment: 1, text: " Today"),
            ])
        #expect(segmenter.pendingText == "Today")
    }

    @Test("句號之後沒有別的字：0.2 秒後一樣併回去")
    func lateLastWordConfirmedByQuiet() throws {
        var segmenter = try cutBeforeTheLastWord()
        _ = segmenter.run([.text(" conference", at: 4.0), .text(".", at: 4.02)])

        #expect(
            segmenter.advance(to: 4.23) == [
                .extended(segment: 0, text: "Good morning everyone and welcome to the conference.")
            ])
        #expect(segmenter.pendingText == "")
    }

    @Test("超過 2 個字就不是尾巴：照常成為新的一段")
    func threeWordsAreANewSegment() throws {
        var segmenter = try cutBeforeTheLastWord()
        let outputs = segmenter.run(words("conference this morning.", from: 4.0, every: 0.05) + [.advance(to: 4.5)])

        #expect(finished(outputs) == [.finished(segment: 1, text: "conference this morning.", reason: .sentenceEnd)])
    }

    @Test("隔了超過 1.5 秒才來的短句不是尾巴")
    func tooLateToBeATail() throws {
        var segmenter = try cutBeforeTheLastWord()
        let outputs = segmenter.run([.text(" Okay", at: 5.5), .text(".", at: 5.51), .advance(to: 5.8)])

        #expect(finished(outputs) == [.finished(segment: 1, text: "Okay.", reason: .sentenceEnd)])
    }

    @Test("上一段不是因為停頓而確定的，就不併")
    func onlyAfterAPauseCut() {
        var segmenter = Segmenter()
        _ = segmenter.run([.text(" Hello", at: 1.0), .text(" world", at: 1.2), .text(".", at: 1.21), .advance(to: 1.5)])
        let outputs = segmenter.run([.text(" Yes", at: 1.6), .text(".", at: 1.61), .advance(to: 1.9)])

        #expect(finished(outputs) == [.finished(segment: 1, text: "Yes.", reason: .sentenceEnd)])
    }

    @Test("併回去之後，再晚到的引號還是補在同一段")
    func amendAfterExtend() throws {
        var segmenter = try cutBeforeTheLastWord()
        _ = segmenter.run([.text(" conference", at: 4.0), .text(".", at: 4.02), .advance(to: 4.23)])

        #expect(
            segmenter.receive("\u{201D}", at: 4.3) == [
                .amended(segment: 0, text: "Good morning everyone and welcome to the conference.\u{201D}")
            ])
    }
}

@Suite("Segmenter：太長、太久、收尾")
struct SegmenterLimitTests {
    private static func configuration() -> Segmenter.Configuration {
        var configuration = Segmenter.Configuration()
        configuration.softWordLimit = 5
        configuration.hardWordLimit = 8
        return configuration
    }

    @Test("超過字數之後，在下一個逗號處切")
    func softLimitCutsAtTheNextComma() {
        var segmenter = Segmenter(configuration: Self.configuration())
        // 逗號太早出現（才 2 個字）不切
        var outputs = segmenter.run([.text(" one", at: 1.0), .text(" two", at: 1.1), .text(",", at: 1.2)])
        outputs += segmenter.run(words("three four five", from: 1.3, every: 0.1) + [.text(",", at: 1.6)])
        #expect(finished(outputs).isEmpty)

        #expect(
            segmenter.receive(" six", at: 1.7) == [
                .finished(segment: 0, text: "one two, three four five,", reason: .tooLong),
                .delta(segment: 1, text: " six"),
            ])
    }

    @Test("到了字數上限還沒有任何標點：直接切")
    func hardLimit() {
        var segmenter = Segmenter(configuration: Self.configuration())
        let outputs = segmenter.run(words("a1 a2 a3 a4 a5 a6 a7 a8", from: 1.0, every: 0.1))
        #expect(finished(outputs).isEmpty)

        #expect(
            segmenter.receive(" a9", at: 1.8) == [
                .finished(segment: 0, text: "a1 a2 a3 a4 a5 a6 a7 a8", reason: .tooLong),
                .delta(segment: 1, text: " a9"),
            ])
    }

    @Test("預設值：25 個字之後遇到逗號才切，40 個字一定切")
    func defaultLimits() {
        let configuration = Segmenter.Configuration()
        #expect(configuration.softWordLimit == 25)
        #expect(configuration.hardWordLimit == 40)

        var segmenter = Segmenter()
        let fortyOne = (1...41).map { "w\($0)" }.joined(separator: " ")
        let outputs = segmenter.run(words(fortyOne, from: 1.0, every: 0.1))
        let expected = (1...40).map { "w\($0)" }.joined(separator: " ")
        #expect(finished(outputs) == [.finished(segment: 0, text: expected, reason: .tooLong)])
    }

    @Test("2 秒沒有新的字：把手上的文字當成一段")
    func idle() {
        var segmenter = Segmenter()
        _ = segmenter.run([.text(" Hello", at: 1.0), .text(" there", at: 1.2)])

        #expect(close(segmenter.nextDeadline, 3.2))
        #expect(segmenter.advance(to: 3.19) == [])
        #expect(segmenter.advance(to: 3.21) == [.finished(segment: 0, text: "Hello there", reason: .idle)])
        #expect(segmenter.nextDeadline == nil)
    }

    @Test("flush：把還沒確定的文字當成一段；沒有文字就什麼都不做；之後段號接著編")
    func flush() {
        var segmenter = Segmenter()
        #expect(segmenter.flush(at: 0.5) == [])
        _ = segmenter.receive(" Hello", at: 1.0)
        #expect(segmenter.pendingText == "Hello")

        #expect(segmenter.flush(at: 1.5) == [.finished(segment: 0, text: "Hello", reason: .flush)])
        #expect(segmenter.flush(at: 1.6) == [])
        #expect(segmenter.receive(" Again", at: 2.0) == [.delta(segment: 1, text: " Again")])
    }

    @Test("一開始沒有任何計時在等")
    func noDeadlineInitially() {
        let segmenter = Segmenter()
        #expect(segmenter.nextDeadline == nil)
        #expect(segmenter.pendingText == "")
    }
}
