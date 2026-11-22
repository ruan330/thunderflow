import Foundation
import Testing
import ThunderCore
import ThunderUI

// 整句模式的字幕（DESIGN.md 4.3、5.6.2 節）：英文帶句子的編號，同一句的段在畫面上合成一個段落；
// 整句定稿（帶 sentenceStart 的中文定稿）到了之前，中文是還在更新的灰字，到了換成整句定稿。

private func delta(_ text: String, _ segment: Int, sentence: Int) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: .zero, segment: segment, sentence: sentence))
}

private func ended(_ text: String, _ segment: Int, sentence: Int) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment, sentence: sentence))
}

private func provisional(_ text: String, _ segment: Int) -> CaptionEvent {
    .provisional(CaptionText(text: text, kind: .delta, at: .zero, segment: segment))
}

/// 一段自己的定稿。
private func final(_ text: String, _ segment: Int) -> CaptionEvent {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

/// 第 `sentence` 句（第 `first` 段到第 `last` 段）的整句定稿。
private func sentenceFinal(_ text: String, sentence: Int, first: Int, last: Int) -> CaptionEvent {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: last, sentence: sentence, sentenceStart: first))
}

private func makeBoard(_ events: [CaptionEvent]) -> CaptionBoard {
    var board = CaptionBoard()
    for event in events { board.apply(event) }
    return board
}

private let chinese = CaptionZoneOptions(language: .chinese, showsProvisional: true, showsFlags: true)
private let english = CaptionZoneOptions(language: .english, showsProvisional: true, showsFlags: false)
private let hidesPeriod = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true, hidesFinalPeriod: true)

private func settled(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .settled, flagged: flagged)
}

private func updating(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .updating, flagged: flagged)
}

private func untranslated(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .untranslated, flagged: flagged)
}

private func paragraphs(_ board: CaptionBoard, _ options: CaptionZoneOptions, marked: Set<Int> = []) -> [CaptionParagraph] {
    CaptionZoneSync.paragraphs(board: board, marked: marked, options: options)
}

@Suite("字幕：整句模式")
struct CaptionBoardSentenceTests {
    @Test("英文記住屬於第幾句；整句定稿放在這一句的最後一段，這一句的每一段都算有定稿")
    func sentenceFinals() {
        var board = CaptionBoard()
        board.apply(delta(" And the reason", 0, sentence: 0))
        #expect(board.liveSentence == 0)
        board.apply(ended("And the reason for that is", 0, sentence: 0))
        board.apply(final("原因是", 0))
        board.apply(ended("that it never occurred.", 1, sentence: 0))
        board.apply(delta(" Next", 2, sentence: 1))
        #expect(board.liveSentence == 1)
        let before = board.revision
        board.apply(sentenceFinal("原因是它從來沒有出現過。", sentence: 0, first: 0, last: 1))

        #expect(board.firstChangedLine(since: before) == 0, "從這一句的第一段開始重畫")
        #expect(board.lines.map(\.sentence) == [0, 0])
        #expect(board.lines.map(\.sentenceChinese) == ["", "原因是它從來沒有出現過。"])
        #expect(board.lines.allSatisfy { $0.coveredBySentence })
        #expect(board.lines.allSatisfy { !$0.untranslated })
    }

    @Test("句子的編號以這一段確定時帶的為準：正在說的時候屬於上一句，確定時改屬下一句（晚到的句號）")
    func relabel() {
        let board = makeBoard([
            ended("So we", 0, sentence: 0), delta(" then", 1, sentence: 0), ended("Then we left.", 1, sentence: 1),
        ])
        #expect(board.lines.map(\.sentence) == [0, 1])
    }

    @Test("下一句的段定稿到了：被整句涵蓋的段不算沒翻到；真的沒有中文的段才算")
    func untranslatedLines() {
        let board = makeBoard([
            ended("First part", 0, sentence: 0), ended("second part.", 1, sentence: 0),
            sentenceFinal("第一句。", sentence: 0, first: 0, last: 1),
            ended("Then", 2, sentence: 1), ended("more", 3, sentence: 1),
            final("更多", 3),
        ])
        #expect(board.lines.map(\.untranslated) == [false, false, true, false])
    }

    @Test("引擎結束：還沒有整句定稿的句子，用各段的定稿接起來當成整句定稿；完全沒有中文的段標成沒翻到")
    func engineEnded() {
        var board = makeBoard([
            ended("So we", 0, sentence: 0), final("所以我們", 0),
            ended("built it", 1, sentence: 0), final("把它做出來", 1),
            ended("Nothing here", 2, sentence: 1),
        ])
        board.engineEnded()
        #expect(board.lines.map(\.sentenceChinese) == ["", "所以我們把它做出來", ""])
        #expect(board.lines.map(\.coveredBySentence) == [true, true, false])
        #expect(board.lines.map(\.untranslated) == [false, false, true])
    }
}

@Suite("字幕區：整句模式")
struct CaptionZoneSentenceTests {
    @Test("同一句的段合成一個段落：中文在整句定稿到之前是還在更新，內容是各段的定稿接起來；到了換成整句定稿")
    func groups() {
        var board = makeBoard([
            ended("And the reason for that is", 0, sentence: 0), final("原因是", 0),
            ended("that it never occurred.", 1, sentence: 0),
        ])
        #expect(paragraphs(board, chinese) == [updating("原因是")])
        #expect(paragraphs(board, english) == [settled("And the reason for that is that it never occurred.")])

        board.apply(sentenceFinal("原因是它從來沒有出現過。", sentence: 0, first: 0, last: 1))
        board.apply(ended("Next one.", 2, sentence: 1))
        #expect(paragraphs(board, chinese) == [settled("原因是它從來沒有出現過。"), updating("…")])
        #expect(paragraphs(board, english) == [settled("And the reason for that is that it never occurred."), settled("Next one.")])
    }

    @Test("正在說的那一段屬於同一句：接在這一句的段落後面，整段還在更新；屬於下一句時自成一段")
    func liveSegment() {
        var board = makeBoard([ended("So when you ask", 0, sentence: 0), delta(" the next", 1, sentence: 0)])
        #expect(paragraphs(board, english) == [updating("So when you ask the next")])
        #expect(paragraphs(board, chinese) == [updating("…")])
        board.apply(provisional("下一個", 1))
        #expect(paragraphs(board, chinese) == [updating("下一個")])

        board = makeBoard([
            ended("Hello there.", 0, sentence: 0), sentenceFinal("哈囉。", sentence: 0, first: 0, last: 0),
            delta(" And", 1, sentence: 1),
        ])
        #expect(paragraphs(board, english) == [settled("Hello there."), updating("And")])
        #expect(paragraphs(board, chinese) == [settled("哈囉。")])
    }

    @Test("中文區可以不顯示句尾的「。」：只拿掉最後一個（後面可以跟著引號或括號），中間的不動；英文區與沒翻到的段落不受影響")
    func finalPeriod() {
        var board = makeBoard([
            ended("One. Two.", 0, sentence: 0), sentenceFinal("第一。第二。", sentence: 0, first: 0, last: 0),
            ended("He said OK.", 1, sentence: 1), sentenceFinal("他說：「好。」", sentence: 1, first: 1, last: 1),
            ended("Really?", 2, sentence: 2), sentenceFinal("真的？", sentence: 2, first: 2, last: 2),
            ended("Lost.", 3, sentence: 3),
        ])
        board.engineEnded()
        #expect(paragraphs(board, hidesPeriod) == [settled("第一。第二"), settled("他說：「好」"), settled("真的？"), untranslated("Lost.")])
        #expect(paragraphs(board, chinese).first == settled("第一。第二。"), "預設照原樣")
        let englishHiding = CaptionZoneOptions(language: .english, showsProvisional: false, showsFlags: false, hidesFinalPeriod: true)
        #expect(paragraphs(board, englishHiding).first == settled("One. Two."))
    }

    @Test("標記：一句裡任何一段被標記，這一句的段落就有旗子")
    func flags() {
        let board = makeBoard([
            ended("A", 0, sentence: 0), ended("b.", 1, sentence: 0), sentenceFinal("甲乙。", sentence: 0, first: 0, last: 1),
            ended("C.", 2, sentence: 1),
        ])
        #expect(paragraphs(board, chinese, marked: [0]) == [settled("甲乙。", flagged: true), updating("…")])
    }

    @Test("最後幾段（浮動字幕用）：和整區的最後幾段相同，包含正在說的那一段；沒有句子編號的字幕也一樣")
    func lastParagraphs() {
        let sentences = makeBoard([
            ended("One.", 0, sentence: 0), sentenceFinal("一。", sentence: 0, first: 0, last: 0),
            ended("Two", 1, sentence: 1), final("二", 1), ended("parts.", 2, sentence: 1),
            ended("Three", 3, sentence: 2), delta(" more", 4, sentence: 2),
        ])
        var plain = CaptionBoard()
        for event: CaptionEvent in [
            .source(CaptionText(text: "One.", kind: .segmentEnd, at: .zero, segment: 0)),
            .translation(CaptionText(text: "一。", kind: .segmentEnd, at: .zero, segment: 0)),
            .source(CaptionText(text: " Two", kind: .delta, at: .zero, segment: 1)),
        ] { plain.apply(event) }
        for board in [sentences, plain] {
            for options in [chinese, english, hidesPeriod] {
                let all = paragraphs(board, options, marked: [1])
                for count in 1...4 {
                    #expect(
                        CaptionZoneSync.lastParagraphs(board: board, marked: [1], options: options, count: count)
                            == Array(all.suffix(count)))
                }
            }
        }
    }

    @Test(
        "模擬一場整句模式（逐字的英文、段的定稿、整句定稿、晚到的句號、漏掉的定稿、標記、換選項、引擎結束）：每一次修改之後都和從頭建立的一樣",
        arguments: [chinese, english, hidesPeriod])
    func simulatedSession(options: CaptionZoneOptions) {
        var random = SplitMix64(seed: 2027)
        var board = CaptionBoard()
        var marked: Set<Int> = []
        var sync = CaptionZoneSync()
        var shown: [CaptionParagraph] = []
        var options = options
        var segment = 0
        var updates = 0

        func check() {
            apply(sync.update(board: board, marked: marked, options: options), to: &shown)
            let expected = CaptionZoneSync.paragraphs(board: board, marked: marked, options: options)
            #expect(shown == expected)
            #expect(sync.paragraphs == shown)
            #expect(sync.updating == Set(shown.indices.filter { shown[$0].kind == .updating }))
            #expect(CaptionZoneSync.lastParagraphs(board: board, marked: marked, options: options, count: 3) == Array(expected.suffix(3)))
            updates += 1
        }

        for sentence in 0..<150 {
            let first = segment
            let count = Int.random(in: 1...3, using: &random)
            for part in 0..<count {
                // 偶爾：正在說的時候還算上一句，確定時才改屬這一句（上一句晚到的句號）
                let liveSentence = part == 0 && sentence > 0 && Double.random(in: 0..<1, using: &random) < 0.1 ? sentence - 1 : sentence
                for word in 0..<Int.random(in: 1...5, using: &random) {
                    board.apply(delta(" w\(segment)-\(word)", segment, sentence: liveSentence))
                    if Double.random(in: 0..<1, using: &random) < 0.3 { board.apply(provisional("暫\(segment)-\(word)", segment)) }
                    if Bool.random(using: &random) { check() }
                }
                let last = part == count - 1
                board.apply(ended(last ? "Part \(segment)." : "Part \(segment)", segment, sentence: sentence))
                // 不是最後一段的段，自己的定稿通常會到
                if !last, Double.random(in: 0..<1, using: &random) < 0.9 { board.apply(final("段\(segment)", segment)) }
                if Double.random(in: 0..<1, using: &random) < 0.05, let line = board.lines.last { marked.insert(line.id) }
                if Bool.random(using: &random) { check() }
                segment += 1
            }
            // 整句定稿通常會到；偶爾整句失敗而且沒有任何段的定稿可以用
            if Double.random(in: 0..<1, using: &random) < 0.9 {
                board.apply(sentenceFinal("第\(sentence)句。", sentence: sentence, first: first, last: segment - 1))
            }
            if sentence == 75 { options.showsProvisional.toggle() }
            if Bool.random(using: &random) { check() }
        }
        board.engineEnded()
        check()
        #expect(updates > 300)
        #expect(shown.count >= 150, "每一句至少一段")
    }
}

/// 照著修改改一份段落，和畫面做的事一樣。修改不合理（位置超出範圍）時記一筆失敗，不會當掉。
private func apply(_ edits: [CaptionZoneSync.Edit], to paragraphs: inout [CaptionParagraph]) {
    for edit in edits {
        switch edit {
        case .set(let index, let paragraph):
            guard index <= paragraphs.count else {
                Issue.record("第 \(index) 段超出範圍（目前 \(paragraphs.count) 段）")
                return
            }
            if index == paragraphs.count { paragraphs.append(paragraph) } else { paragraphs[index] = paragraph }
        case .truncate(let index):
            guard index <= paragraphs.count else {
                Issue.record("從第 \(index) 段刪起超出範圍（目前 \(paragraphs.count) 段）")
                return
            }
            paragraphs.removeLast(paragraphs.count - index)
        }
    }
}

/// 固定種子的亂數：每次跑的結果都一樣。
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
