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

private func makeBoard(_ events: [CaptionEvent]) -> CaptionBoard {
    var board = CaptionBoard()
    for event in events { board.apply(event) }
    return board
}

private let chinese = CaptionZoneOptions(language: .chinese, showsProvisional: true, showsFlags: true)
private let english = CaptionZoneOptions(language: .english, showsProvisional: true, showsFlags: false)
private let chineseWithoutProvisional = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true)

private func settled(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .settled, flagged: flagged)
}

private func updating(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .updating, flagged: flagged)
}

private func untranslated(_ text: String, flagged: Bool = false) -> CaptionParagraph {
    CaptionParagraph(text: text, kind: .untranslated, flagged: flagged)
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

@Suite("字幕區的段落：每一行要顯示什麼")
struct CaptionParagraphTests {
    @Test("中文區：有定稿顯示定稿；定稿還沒到時顯示暫定譯文（沒有時是「…」）並標成還在更新；沒翻到的顯示英文")
    func chineseLines() {
        let board = makeBoard([
            ended("Zero.", 0), final("零。", 0),
            ended("One.", 1), provisional("一", 1),
            ended("Two.", 2),
            ended("Three.", 3), ended("Four.", 4), final("四。", 4),
        ])
        // 第 4 段的定稿到了，前面的 1–3 段就是沒翻到
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [], options: chinese) == [
                settled("零。"), untranslated("One."), untranslated("Two."), untranslated("Three."), settled("四。"),
            ])

        let waiting = makeBoard([ended("Zero.", 0), provisional("零", 0), ended("One.", 1)])
        #expect(
            CaptionZoneSync.paragraphs(board: waiting, marked: [], options: chinese) == [updating("零"), updating("…")])
    }

    @Test("中文區：正在說的那一段有暫定譯文時加在最後；關閉暫定譯文時不顯示，定稿還沒到的行只顯示「…」")
    func chineseLive() {
        let board = makeBoard([ended("Zero.", 0), provisional("零", 0), delta(" One", 1), provisional("一", 1)])
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [], options: chinese) == [updating("零"), updating("一")])

        let hidden = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true)
        #expect(CaptionZoneSync.paragraphs(board: board, marked: [], options: hidden) == [updating("…")])
    }

    @Test("英文區：每一行是英文；正在說的那一段去掉前後的空白加在最後，沒有字時不加")
    func englishLines() {
        let board = makeBoard([ended("Zero.", 0), final("零。", 0), ended("One.", 1), delta(" Two", 2), delta(" more ", 2)])
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [], options: english) == [
                settled("Zero."), settled("One."), updating("Two more"),
            ])

        let blank = makeBoard([ended("Zero.", 0), delta(" ", 1)])
        #expect(CaptionZoneSync.paragraphs(board: blank, marked: [], options: english) == [settled("Zero.")])
    }

    @Test("標記重點：只有畫旗子的那一區、被標記的那一行有旗子；正在說的那一段不會有")
    func flags() {
        let board = makeBoard([ended("Zero.", 0), final("零。", 0), ended("One.", 1), delta(" Two", 2), provisional("二", 2)])
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [1], options: chinese) == [
                settled("零。"), updating("…", flagged: true), updating("二"),
            ])
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [1], options: english) == [
                settled("Zero."), settled("One."), updating("Two"),
            ])
        let englishOnly = CaptionZoneOptions(language: .english, showsProvisional: true, showsFlags: true)
        #expect(
            CaptionZoneSync.paragraphs(board: board, marked: [0], options: englishOnly) == [
                settled("Zero.", flagged: true), settled("One."), updating("Two"),
            ])
    }
}

@Suite("字幕區的增量更新：只改有變的段")
struct CaptionZoneSyncTests {
    @Test("第一次更新：每一行一段，最後是正在說的那一段；之後沒有改變時沒有任何修改")
    func first() {
        let board = makeBoard([ended("Zero.", 0), ended("One.", 1), delta(" Two", 2)])
        var sync = CaptionZoneSync()
        var shown: [CaptionParagraph] = []
        apply(sync.update(board: board, marked: [], options: english), to: &shown)
        #expect(shown == [settled("Zero."), settled("One."), updating("Two")])
        #expect(sync.paragraphs == shown)
        #expect(sync.update(board: board, marked: [], options: english).isEmpty)
    }

    @Test("只有正在說的那一段改變：只改最後一段")
    func liveOnly() {
        var board = makeBoard([ended("Zero.", 0), ended("One.", 1), delta(" Two", 2)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: english)
        board.apply(delta(" more", 2))
        #expect(sync.update(board: board, marked: [], options: english) == [.set(2, updating("Two more"))])
    }

    @Test("新的一行確定：它取代原本正在說的那一段；沒有新的正在說的那一段時刪掉多出來的段")
    func newLine() {
        var board = makeBoard([ended("Zero.", 0), ended("One.", 1), delta(" Two", 2)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: english)
        board.apply(ended("Two.", 2))
        #expect(sync.update(board: board, marked: [], options: english) == [.set(2, settled("Two."))])

        board.apply(delta(" Three", 3))
        _ = sync.update(board: board, marked: [], options: english)
        board.apply(ended("Three.", 3))
        board.apply(ended("Four.", 4))
        #expect(
            sync.update(board: board, marked: [], options: english) == [.set(3, settled("Three.")), .set(4, settled("Four."))])
    }

    @Test("正在說的那一段沒了（例如被併進上一行）：刪掉最後一段")
    func liveRemoved() {
        var board = makeBoard([ended("Zero.", 0), delta(" and more", 1)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: english)
        board.apply(ended("Zero and more.", 0))
        #expect(sync.update(board: board, marked: [], options: english) == [.set(0, settled("Zero and more.")), .truncate(1)])
    }

    @Test("定稿到了：只改那一行，其他行不動")
    func translationArrives() {
        var board = makeBoard([ended("Zero.", 0), final("零。", 0), ended("One.", 1), ended("Two.", 2)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: chinese)
        board.apply(final("一。", 1))
        #expect(sync.update(board: board, marked: [], options: chinese) == [.set(1, settled("一。"))])
    }

    @Test("標記重點：只改被標記的那一行")
    func mark() {
        let board = makeBoard([ended("Zero.", 0), final("零。", 0), ended("One.", 1), final("一。", 1)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: chinese)
        #expect(sync.update(board: board, marked: [1], options: chinese) == [.set(1, settled("一。", flagged: true))])
        #expect(sync.update(board: board, marked: [1], options: chinese).isEmpty)
    }

    @Test("換了顯示的選項：整區從頭重畫")
    func optionsChanged() {
        let board = makeBoard([ended("Zero.", 0), provisional("零", 0), delta(" One", 1), provisional("一", 1)])
        var sync = CaptionZoneSync()
        var shown: [CaptionParagraph] = []
        apply(sync.update(board: board, marked: [], options: chinese), to: &shown)
        let hidden = CaptionZoneOptions(language: .chinese, showsProvisional: false, showsFlags: true)
        let edits = sync.update(board: board, marked: [], options: hidden)
        #expect(edits.first == .truncate(0))
        apply(edits, to: &shown)
        #expect(shown == [updating("…")])
    }

    @Test("換了一份字幕（下一場）：整區從頭重畫")
    func newBoard() {
        let first = makeBoard([ended("Zero.", 0), ended("One.", 1)])
        var sync = CaptionZoneSync()
        var shown: [CaptionParagraph] = []
        apply(sync.update(board: first, marked: [], options: english), to: &shown)
        let second = makeBoard([ended("Hello.", 0)])
        let edits = sync.update(board: second, marked: [], options: english)
        #expect(edits.first == .truncate(0))
        apply(edits, to: &shown)
        #expect(shown == [settled("Hello.")])
    }

    @Test("綠線：記得哪幾段還在更新")
    func updatingParagraphs() {
        var board = makeBoard([ended("Zero.", 0), final("零。", 0), ended("One.", 1), delta(" Two", 2), provisional("二", 2)])
        var sync = CaptionZoneSync()
        _ = sync.update(board: board, marked: [], options: chinese)
        #expect(sync.updating == [1, 2])
        board.apply(final("一。", 1))
        _ = sync.update(board: board, marked: [], options: chinese)
        #expect(sync.updating == [2])
    }

    @Test(
        "模擬一場（逐字的英文、暫定譯文、晚到與漏掉的定稿、補上的標點、標記、換選項、引擎結束）：每一次修改之後都和從頭建立的一樣",
        arguments: [chinese, english, chineseWithoutProvisional])
    func simulatedSession(options: CaptionZoneOptions) {
        var random = SplitMix64(seed: 2026)
        var board = CaptionBoard()
        var marked: Set<Int> = []
        var sync = CaptionZoneSync()
        var shown: [CaptionParagraph] = []
        var options = options
        var pending: [Int] = []
        var updates = 0

        func check() {
            apply(sync.update(board: board, marked: marked, options: options), to: &shown)
            let expected = CaptionZoneSync.paragraphs(board: board, marked: marked, options: options)
            #expect(shown == expected)
            #expect(sync.paragraphs == shown)
            #expect(sync.updating == Set(shown.indices.filter { shown[$0].kind == .updating }))
            updates += 1
        }

        for segment in 0..<400 {
            for word in 0..<Int.random(in: 1...6, using: &random) {
                board.apply(delta(" w\(segment)-\(word)", segment))
                if Double.random(in: 0..<1, using: &random) < 0.3 { board.apply(provisional("暫\(segment)-\(word)", segment)) }
                if Bool.random(using: &random) { check() }
            }
            board.apply(ended("Segment \(segment).", segment))
            pending.append(segment)
            if Double.random(in: 0..<1, using: &random) < 0.1 { board.apply(ended("Segment \(segment)!", segment)) }
            if let waiting = pending.first, Double.random(in: 0..<1, using: &random) < 0.3 {
                board.apply(provisional("暫定 \(waiting)", waiting))
            }
            // 定稿通常晚一兩段才到；偶爾整段漏掉（之後的定稿到了，它就變成未翻譯）
            while pending.count > Int.random(in: 0...2, using: &random) {
                let next = pending.removeFirst()
                if Double.random(in: 0..<1, using: &random) < 0.9 { board.apply(final("中文 \(next)", next)) }
            }
            if Double.random(in: 0..<1, using: &random) < 0.05, let last = board.lines.last { marked.insert(last.id) }
            if segment == 200 { options.showsProvisional.toggle() }
            if Bool.random(using: &random) { check() }
        }
        board.engineEnded()
        check()
        #expect(board.lines.count == 400)
        #expect(shown.count >= 400, "每一行都要有一段")
        #expect(updates > 400)
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
