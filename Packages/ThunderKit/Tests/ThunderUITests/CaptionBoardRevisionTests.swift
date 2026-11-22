import Foundation
import Testing
import ThunderCore
import ThunderUI

private func delta(_ text: String, _ segment: Int?) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: .zero, segment: segment))
}

private func ended(_ text: String, _ segment: Int?) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

private func provisional(_ text: String, _ segment: Int?) -> CaptionEvent {
    .provisional(CaptionText(text: text, kind: .delta, at: .zero, segment: segment))
}

private func final(_ text: String, _ segment: Int?) -> CaptionEvent {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

/// 已經確定了 `count` 段英文（段號 0 起）的字幕，還沒有任何中文。
private func makeBoard(lines count: Int) -> CaptionBoard {
    var board = CaptionBoard()
    for segment in 0..<count { board.apply(ended("Segment \(segment).", segment)) }
    return board
}

@Suite("字幕的版本：畫面只重畫改過的行")
struct CaptionBoardRevisionTests {
    @Test("新的一行確定時版本加一，從那一行開始要重畫；只有正在說的那一段改變時不算改到任何一行")
    func newLine() {
        var board = CaptionBoard()
        board.apply(delta(" Today", 0))
        board.apply(provisional("今天", 0))
        #expect(board.revision == 0)
        #expect(board.firstChangedLine(since: 0) == nil)

        board.apply(ended("Today.", 0))
        #expect(board.revision == 1)
        #expect(board.firstChangedLine(since: 0) == 0)
        #expect(board.firstChangedLine(since: 1) == nil)

        board.apply(delta(" Next", 1))
        board.apply(ended("Next.", 1))
        #expect(board.revision == 2)
        #expect(board.firstChangedLine(since: 1) == 1)
        #expect(board.firstChangedLine(since: 0) == 0)
    }

    @Test("改到已經確定的行（定稿、那一行的暫定譯文、補上的標點）：從被改到的那一行開始")
    func existingLines() throws {
        var board = makeBoard(lines: 5)
        var seen = board.revision

        board.apply(provisional("第四段", 4))
        #expect(board.firstChangedLine(since: seen) == 4)
        seen = board.revision

        board.apply(ended("Segment 3!", 3))
        #expect(board.firstChangedLine(since: seen) == 3)
        #expect(board.lines.count == 5)
        seen = board.revision

        // 好幾次改變：取最前面的那一行
        board.apply(provisional("第五段", 4))
        board.apply(ended("Segment 2!", 2))
        #expect(board.firstChangedLine(since: seen) == 2)
    }

    @Test("晚到的定稿讓前面還沒有中文的行變成未翻譯：從最前面被改到的那一行開始")
    func lateTranslationMarksEarlierLines() {
        var board = makeBoard(lines: 6)
        board.apply(final("第零段", 0))
        let seen = board.revision

        board.apply(final("第四段", 4))
        // 第 1–3 段沒翻到
        #expect(board.lines[1].untranslated)
        #expect(board.firstChangedLine(since: seen) == 1)
    }

    @Test("引擎結束：從第一行還沒有中文的開始；每一行都有中文時不算改變")
    func engineEnded() {
        var board = makeBoard(lines: 4)
        for segment in 0..<2 { board.apply(final("中文\(segment)", segment)) }
        var seen = board.revision
        board.engineEnded()
        #expect(board.firstChangedLine(since: seen) == 2)

        var complete = makeBoard(lines: 3)
        for segment in 0..<3 { complete.apply(final("中文\(segment)", segment)) }
        seen = complete.revision
        complete.engineEnded()
        #expect(complete.firstChangedLine(since: seen) == nil)
    }

    @Test("問很久以前的版本：回答的那一行不會比真正改到的晚（紀錄丟掉時從頭比對），最近的版本照樣答得準")
    func oldRevisions() {
        var board = makeBoard(lines: 10)
        let early = board.revision
        // 最後一行的暫定譯文改了兩千次
        for version in 0..<2_000 { board.apply(provisional("暫定 \(version)", 9)) }
        #expect(board.revision == early + 2_000)
        #expect((board.firstChangedLine(since: early) ?? .max) <= 9)
        #expect(board.firstChangedLine(since: 0) == 0)
        #expect(board.firstChangedLine(since: board.revision - 1) == 9)
    }

    @Test("用段號找行：找得到時回傳它的位置，找不到是 nil")
    func lineIndex() {
        var board = CaptionBoard()
        for segment in [0, 1, 3, 4] { board.apply(ended("Segment \(segment).", segment)) }
        #expect(board.index(ofLine: 0) == 0)
        #expect(board.index(ofLine: 3) == 2)
        #expect(board.index(ofLine: 4) == 3)
        #expect(board.index(ofLine: 2) == nil)
        #expect(board.index(ofLine: 9) == nil)
    }

    @Test("每一份字幕有自己的識別：複製的是同一份，清空重來的是另一份")
    func identity() {
        let board = makeBoard(lines: 2)
        let copy = board
        #expect(copy.identity == board.identity)
        #expect(CaptionBoard().identity != board.identity)
    }
}
