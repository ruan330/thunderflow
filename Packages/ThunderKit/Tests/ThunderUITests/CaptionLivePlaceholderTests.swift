import Foundation
import Testing
import ThunderCore
import ThunderUI

// 正在說、自成一段的那一段（DESIGN.md 4.3 節）：英文區顯示目前的英文，標成還在更新（左邊的綠線）；
// 中文區同時出現一段：有暫定譯文時是暫定譯文，還沒有（或關掉了暫定譯文）時是「…」，一樣標成還在更新。
// 負責人回報（2026-11-25）：關掉暫定譯文時，中文區要等英文那一段說完才出現「…」與綠線，看起來像中文的最新一句沒有出來。

private func delta(_ text: String, _ segment: Int, sentence: Int? = nil) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: .zero, segment: segment, sentence: sentence))
}

private func ended(_ text: String, _ segment: Int, sentence: Int? = nil) -> CaptionEvent {
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
private let chineseNoPeriod = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true, hidesFinalPeriod: true)
private let english = CaptionZoneOptions(language: .english, showsProvisional: false, showsFlags: false)

private func settled(_ text: String) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .settled, flagged: false)
}

private func updating(_ text: String) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .updating, flagged: false)
}

private func paragraphs(_ board: CaptionBoard, _ options: CaptionZoneOptions) -> [CaptionParagraph] {
    CaptionZoneSync.paragraphs(board: board, marked: [], options: options)
}

/// 第 0 句已經有整句定稿；第 1 句剛開始說。
private let nextSentence: [CaptionEvent] = [
    delta(" Hello there", 0, sentence: 0),
    ended("Hello there.", 0, sentence: 0),
    sentenceFinal("哈囉。", sentence: 0, first: 0, last: 0),
    delta(" And then we", 1, sentence: 1),
]

@Suite("字幕：正在說的那一段，中文區也一起出現")
struct CaptionLivePlaceholderTests {
    @Test("關掉暫定譯文、下一句開始說：中文區立刻有一段「…」，和英文區正在說的那一段一起標成還在更新")
    func provisionalOffNextSentence() {
        let board = makeBoard(nextSentence)
        #expect(paragraphs(board, english) == [settled("Hello there."), updating("And then we")])
        #expect(paragraphs(board, chineseNoProvisional) == [settled("哈囉。"), updating("…")])
    }

    @Test("關掉暫定譯文、正在說的那一段說完了：「…」留在這一行，等它的定稿")
    func provisionalOffSegmentEnds() {
        var board = makeBoard(nextSentence)
        board.apply(ended("And then we left.", 1, sentence: 1))
        #expect(paragraphs(board, chineseNoProvisional) == [settled("哈囉。"), updating("…")])
        board.apply(sentenceFinal("然後我們就離開了。", sentence: 1, first: 1, last: 1))
        #expect(paragraphs(board, chineseNoProvisional) == [settled("哈囉。"), settled("然後我們就離開了。")])
    }

    @Test("不分句（沒有句子的編號）、關掉暫定譯文：正在說的那一段，中文區也是「…」")
    func withoutSentences() {
        let board = makeBoard([ended("Zero.", 0), final("零。", 0), delta(" One", 1)])
        #expect(paragraphs(board, english) == [settled("Zero."), updating("One")])
        #expect(paragraphs(board, chineseNoProvisional) == [settled("零。"), updating("…")])
    }

    @Test("開著暫定譯文、這一句的暫定譯文還沒到：先顯示「…」，到了換成暫定譯文")
    func provisionalOnBeforeDraft() {
        var board = makeBoard(nextSentence)
        #expect(paragraphs(board, chinese) == [settled("哈囉。"), updating("…")])
        board.apply(draft("然後我們", sentence: 1, first: 1, segment: 1))
        #expect(paragraphs(board, chinese) == [settled("哈囉。"), updating("然後我們")])
    }

    @Test("正在說的那一段只有空白：英文區不加，中文區也不加")
    func blankLiveSegment() {
        let board = makeBoard([ended("Zero.", 0), final("零。", 0), delta(" ", 1)])
        #expect(paragraphs(board, english) == [settled("Zero.")])
        #expect(paragraphs(board, chineseNoProvisional) == [settled("零。")])
        #expect(paragraphs(board, chinese) == [settled("零。")])
    }

    @Test("浮動字幕的最後兩段：中文區也有正在說的那一段的「…」；句尾不顯示「。」的設定不影響它")
    func floatingCaptions() {
        let board = makeBoard(nextSentence)
        #expect(
            CaptionZoneSync.lastParagraphs(board: board, marked: [], options: chineseNoPeriod, count: 2)
                == [settled("哈囉"), updating("…")])
    }

    @Test("增量更新：每一個事件之後，畫面上的段落都和整個重算的結果相同")
    func incrementalMatchesFull() {
        let events = nextSentence + [
            draft("然後我們", sentence: 1, first: 1, segment: 1),
            ended("And then we left.", 1, sentence: 1),
            delta(" Later", 2, sentence: 2),
            sentenceFinal("然後我們就離開了。", sentence: 1, first: 1, last: 1),
            delta(" on", 2, sentence: 2),
            ended("Later on.", 2, sentence: 2),
            delta(" ", 3, sentence: 3),
            delta(" Bye", 3, sentence: 3),
        ]
        for options in [chinese, chineseNoProvisional, chineseNoPeriod, english] {
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
