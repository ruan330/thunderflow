import Foundation
import Testing
import ThunderCore
import ThunderUI

// 整句的暫定譯文（DESIGN.md 4.3、5.6.2 節）：正在說的那一句，中文顯示「這一句目前聽到的部分」的整句暫定譯文（灰字），
// 取代各段自己的定稿與逐段的暫定譯文；整句定稿到了換成白字。關掉暫定譯文時照舊顯示各段的定稿。

private func delta(_ text: String, _ segment: Int, sentence: Int) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: .zero, segment: segment, sentence: sentence))
}

private func ended(_ text: String, _ segment: Int, sentence: Int) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment, sentence: sentence))
}

/// 一段自己的定稿。
private func final(_ text: String, _ segment: Int) -> CaptionEvent {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

/// 第 `sentence` 句（從第 `first` 段開始，目前到第 `segment` 段）的整句暫定譯文。
private func draft(_ text: String, sentence: Int, first: Int, segment: Int) -> CaptionEvent {
    .provisional(CaptionText(text: text, kind: .delta, at: .zero, segment: segment, sentence: sentence, sentenceStart: first))
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
private let chineseNoProvisional = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true)
private let chineseNoPeriod = CaptionZoneOptions(language: .chinese, showsProvisional: true, showsFlags: true, hidesFinalPeriod: true)
private let english = CaptionZoneOptions(language: .english, showsProvisional: true, showsFlags: false)

private func settled(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .settled, flagged: flagged)
}

private func updating(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .updating, flagged: flagged)
}

private func paragraphs(_ board: CaptionBoard, _ options: CaptionZoneOptions, marked: Set<Int> = []) -> [CaptionParagraph] {
    CaptionZoneSync.paragraphs(board: board, marked: marked, options: options)
}

/// 第 0 句說到一半：第 0 段確定（有自己的定稿），第 1 段還在說，整句的暫定譯文到了。
private let halfway: [CaptionEvent] = [
    delta(" So the first thing", 0, sentence: 0),
    draft("所以第一件事", sentence: 0, first: 0, segment: 0),
    ended("So the first thing", 0, sentence: 0),
    final("所以第一件事情", 0),
    delta(" we did", 1, sentence: 0),
    draft("所以我們做的第一件事", sentence: 0, first: 0, segment: 1),
]

@Suite("字幕：整句的暫定譯文")
struct CaptionDraftTests {
    @Test("正在說的那一句：中文顯示整句的暫定譯文（灰字），不顯示各段自己的定稿；英文照舊")
    func showsDraft() {
        let board = makeBoard(halfway)
        #expect(paragraphs(board, chinese) == [updating("所以我們做的第一件事")])
        #expect(paragraphs(board, english) == [updating("So the first thing we did")])
        #expect(board.draft == CaptionBoard.Draft(sentence: 0, first: 0, text: "所以我們做的第一件事"))
    }

    @Test("整句定稿到了換成白字，暫定譯文清掉；句尾的「。」照設定不顯示")
    func replacedByFinal() {
        var board = makeBoard(halfway)
        board.apply(ended("we did was this.", 1, sentence: 0))
        #expect(paragraphs(board, chinese) == [updating("所以我們做的第一件事")], "整句定稿到之前仍然顯示暫定譯文")
        board.apply(sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 1))
        #expect(board.draft == nil)
        #expect(paragraphs(board, chinese) == [settled("我們做的第一件事就是這個。")])
        #expect(paragraphs(board, chineseNoPeriod) == [settled("我們做的第一件事就是這個")])
    }

    @Test("這一句的第一段還在說（還沒有確定的段）：進行中的那一行顯示整句的暫定譯文")
    func liveOnly() {
        let board = makeBoard([
            delta(" One two three", 0, sentence: 0),
            draft("一二三", sentence: 0, first: 0, segment: 0),
        ])
        #expect(paragraphs(board, chinese) == [updating("一二三")])
    }

    @Test("段與段之間的停頓（沒有進行中的文字）：仍然顯示這一句的暫定譯文")
    func betweenSegments() {
        let board = makeBoard(Array(halfway.prefix(4)))
        #expect(board.liveEnglish.isEmpty)
        #expect(paragraphs(board, chinese) == [updating("所以第一件事")])
    }

    @Test("關掉暫定譯文：照舊顯示各段自己的定稿接起來")
    func provisionalOff() {
        let board = makeBoard(halfway)
        #expect(paragraphs(board, chineseNoProvisional) == [updating("所以第一件事情")])
    }

    @Test("上一句說完、下一句在說：上一句是白字，下一句是它自己的暫定譯文；浮動字幕的最後幾段也一樣")
    func nextSentence() {
        var board = makeBoard(halfway)
        board.apply(ended("we did was this.", 1, sentence: 0))
        board.apply(sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 1))
        board.apply(delta(" And then", 2, sentence: 1))
        #expect(paragraphs(board, chinese) == [settled("我們做的第一件事就是這個。"), updating("…")], "下一句還沒有暫定譯文：先顯示「…」，不顯示上一句的")
        board.apply(draft("然後", sentence: 1, first: 2, segment: 2))
        #expect(paragraphs(board, chinese) == [settled("我們做的第一件事就是這個。"), updating("然後")])
        #expect(
            CaptionZoneSync.lastParagraphs(board: board, marked: [], options: chineseNoPeriod, count: 2)
                == [settled("我們做的第一件事就是這個"), updating("然後")])
    }

    @Test("別句的暫定譯文（已經說完的那一句）不採用")
    func ignoresClosedSentence() {
        var board = makeBoard(halfway)
        board.apply(ended("we did was this.", 1, sentence: 0))
        board.apply(sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 1))
        board.apply(draft("晚到的暫定譯文", sentence: 0, first: 0, segment: 1))
        #expect(board.draft == nil)
        #expect(paragraphs(board, chinese) == [settled("我們做的第一件事就是這個。")])
    }

    @Test("錄音結束：沒有整句定稿的那一句不再顯示暫定譯文，照舊用各段的定稿接起來")
    func engineEnded() {
        var board = makeBoard(halfway)
        board.apply(ended("we did", 1, sentence: 0))
        board.engineEnded()
        #expect(board.draft == nil)
        #expect(paragraphs(board, chinese).allSatisfy { $0.kind != .updating })
    }

    @Test("增量更新：每一個事件之後，畫面上的段落都和整個重算的結果相同")
    func incrementalMatchesFull() {
        let events = halfway + [
            ended("we did was this.", 1, sentence: 0),
            sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 1),
            delta(" And then", 2, sentence: 1),
            draft("然後", sentence: 1, first: 2, segment: 2),
            ended("And then", 2, sentence: 1),
            draft("然後呢", sentence: 1, first: 2, segment: 2),
            delta(" we left.", 3, sentence: 1),
            draft("然後我們就離開了", sentence: 1, first: 2, segment: 3),
        ]
        for options in [chinese, chineseNoPeriod, chineseNoProvisional, english] {
            var board = CaptionBoard()
            var zone = CaptionZoneSync()
            for (index, event) in events.enumerated() {
                board.apply(event)
                _ = zone.update(board: board, marked: [], options: options)
                #expect(zone.paragraphs == paragraphs(board, options), "第 \(index) 個事件之後（\(options.language)）")
            }
        }
    }
}
