import Foundation
import Testing
import ThunderCore
import ThunderUI

// 整句的暫定譯文（DESIGN.md 4.3、5.6.2 節）：上一句說完了、它的整句定稿還沒到，下一句已經開始說，下一句的暫定譯文先到了。
// 上一句要繼續顯示它自己的暫定譯文，直到它的整句定稿到了換成白字；不可以變成「…」，也不可以換成各段自己的定稿（後半句不見）。
// 講者句子之間不停頓時很常見：下一句的中文約 0.7 秒就出現，上一句的整句定稿中位數約 0.9 秒、P90 約 1.8 秒。

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

private func settled(_ text: String) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .settled, flagged: false)
}

private func updating(_ text: String) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .updating, flagged: false)
}

private func paragraphs(_ board: CaptionBoard, _ options: CaptionZoneOptions) -> [CaptionParagraph] {
    CaptionZoneSync.paragraphs(board: board, marked: [], options: options)
}

/// 第 0 句只有一段：說完了，整句定稿還沒到；第 1 句開始說，它的暫定譯文到了。
private let singleSegment: [CaptionEvent] = [
    delta(" So the first thing we did", 0, sentence: 0),
    draft("所以我們做的第一件事", sentence: 0, first: 0, segment: 0),
    ended("So the first thing we did was this.", 0, sentence: 0),
    delta(" And then", 1, sentence: 1),
    draft("然後", sentence: 1, first: 1, segment: 1),
]

/// 第 0 句有兩段，第 0 段有自己的定稿；第 0 句說完了，整句定稿還沒到；第 2 段（第 1 句）的暫定譯文到了。
private let twoSegments: [CaptionEvent] = [
    delta(" So the first thing", 0, sentence: 0),
    draft("所以第一件事", sentence: 0, first: 0, segment: 0),
    ended("So the first thing", 0, sentence: 0),
    final("所以第一件事情", 0),
    delta(" we did was this", 1, sentence: 0),
    draft("所以我們做的第一件事就是這個", sentence: 0, first: 0, segment: 1),
    ended("we did was this.", 1, sentence: 0),
    delta(" And then", 2, sentence: 1),
    draft("然後", sentence: 1, first: 2, segment: 2),
]

@Suite("字幕：整句的暫定譯文，上一句的整句定稿還沒到、下一句已經開始")
struct CaptionDraftOverlapTests {
    @Test("上一句只有一段：仍然顯示它自己的暫定譯文，不會變成「…」；整句定稿到了換成白字，下一句照樣顯示它自己的")
    func singleSegmentKeepsDraft() {
        var board = makeBoard(singleSegment)
        #expect(paragraphs(board, chinese) == [updating("所以我們做的第一件事"), updating("然後")])
        #expect(board.draft == CaptionBoard.Draft(sentence: 1, first: 1, text: "然後"), "最近一句的暫定譯文")

        board.apply(sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 0))
        #expect(paragraphs(board, chinese) == [settled("我們做的第一件事就是這個。"), updating("然後")])
        #expect(board.draft == CaptionBoard.Draft(sentence: 1, first: 1, text: "然後"))
    }

    @Test("上一句有好幾段：仍然顯示整句的暫定譯文，不會換成各段自己的定稿（後半句不見）")
    func severalSegmentsKeepDraft() {
        let board = makeBoard(twoSegments)
        #expect(paragraphs(board, chinese) == [updating("所以我們做的第一件事就是這個"), updating("然後")])
        #expect(paragraphs(board, english) == [settled("So the first thing we did was this."), updating("And then")])
    }

    @Test("關掉暫定譯文：照舊顯示各段自己的定稿接起來；正在說的下一句是「…」")
    func provisionalOff() {
        let board = makeBoard(twoSegments)
        #expect(paragraphs(board, chineseNoProvisional) == [updating("所以第一件事情"), updating("…")])
    }

    @Test("連續兩句都說完了、整句定稿都還沒到：每一句各自顯示自己的暫定譯文")
    func twoPendingSentences() {
        let board = makeBoard(singleSegment + [
            ended("And then we left.", 1, sentence: 1),
            draft("然後我們就離開了", sentence: 1, first: 1, segment: 1),
            delta(" Later", 2, sentence: 2),
            draft("後來", sentence: 2, first: 2, segment: 2),
        ])
        #expect(paragraphs(board, chinese) == [updating("所以我們做的第一件事"), updating("然後我們就離開了"), updating("後來")])
    }

    @Test("浮動字幕的最後兩段：上一句仍然是它自己的暫定譯文")
    func floatingCaptions() {
        let board = makeBoard(singleSegment)
        #expect(
            CaptionZoneSync.lastParagraphs(board: board, marked: [], options: chineseNoPeriod, count: 2)
                == [updating("所以我們做的第一件事"), updating("然後")])
    }

    @Test("錄音結束：每一句的暫定譯文都清掉，沒有任何一段還在更新")
    func engineEndedClearsAll() {
        var board = makeBoard(singleSegment + [ended("And then", 1, sentence: 1)])
        board.engineEnded()
        #expect(board.draft == nil)
        #expect(paragraphs(board, chinese).allSatisfy { $0.kind != .updating })
    }

    @Test("增量更新：句子重疊時，每一個事件之後，畫面上的段落都和整個重算的結果相同")
    func incrementalMatchesFull() {
        let events = twoSegments + [
            final("我們做的就是這個", 1),
            ended("And then", 2, sentence: 1),
            draft("然後呢", sentence: 1, first: 2, segment: 2),
            sentenceFinal("我們做的第一件事就是這個。", sentence: 0, first: 0, last: 1),
            delta(" we left", 3, sentence: 1),
            draft("然後我們就離開了", sentence: 1, first: 2, segment: 3),
            ended("we left.", 3, sentence: 1),
            delta(" Later", 4, sentence: 2),
            draft("後來", sentence: 2, first: 4, segment: 4),
            sentenceFinal("然後我們就離開了。", sentence: 1, first: 2, last: 3),
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
