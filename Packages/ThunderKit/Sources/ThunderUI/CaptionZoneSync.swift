import Foundation
import ThunderCore

/// 一區字幕裡的一段：一行字幕，或正在說的那一段（DESIGN.md 4.3、4.10.4 節）。
public struct CaptionParagraph: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 確定的內容：中文定稿，或英文區的一行。
        case settled
        /// 還在更新：中文定稿還沒到時的暫定譯文（沒有時是「…」）、正在說的那一段。左邊一條綠線。
        case updating
        /// 這一段沒翻到：先顯示英文，後面標「未翻譯」。
        case untranslated
    }

    public var text: String
    public var kind: Kind
    /// 標記過重點：後面一面黃色旗子。
    public var flagged: Bool

    public init(text: String, kind: Kind, flagged: Bool) {
        self.text = text
        self.kind = kind
        self.flagged = flagged
    }
}

/// 一區字幕顯示什麼。
public struct CaptionZoneOptions: Sendable, Equatable {
    public enum Language: Sendable, Equatable {
        case chinese
        case english
    }

    public var language: Language
    /// 中文區：定稿到之前顯示暫定譯文。
    public var showsProvisional: Bool
    /// 這一區畫標記的旗子（雙語時只畫在中文區）。
    public var showsFlags: Bool
    /// 中文區：每一段最後的「。」不顯示（字幕的寫法）。句子中間的句號照樣顯示。
    public var hidesFinalPeriod: Bool

    public init(language: Language, showsProvisional: Bool, showsFlags: Bool, hidesFinalPeriod: Bool = false) {
        self.language = language
        self.showsProvisional = showsProvisional
        self.showsFlags = showsFlags
        self.hidesFinalPeriod = hidesFinalPeriod
    }
}

/// 一區字幕畫了什麼，以及下一次要怎麼改（DESIGN.md 9.8 節：每一次更新的成本不隨場次變長）。
///
/// 每一行字幕是一段；整句模式時，同一句的行合成一段（DESIGN.md 4.3 節）。最後可能再加上正在說的那一段，
/// 它屬於最後那一句（而且那一句還沒有整句定稿）時，接在那一句的段落後面。
/// 這裡記住上一次畫到 `CaptionBoard` 的哪一版、每一段從第幾行開始，這一次只重算之後改過的行所在的段、
/// 標記有變的行與最後的段，算出最少的修改（`Edit`）。畫面照著改，不必整區重畫，也不必拿著整份字幕。
/// 換了顯示的選項或換了一份字幕（下一場）時從頭重畫。
public struct CaptionZoneSync: Sendable {
    public enum Edit: Sendable, Equatable {
        /// 第 `index` 段換成新的內容；`index` 等於目前的段數時加在最後。
        case set(Int, CaptionParagraph)
        /// 刪掉第 `index` 段以及之後的所有段。
        case truncate(Int)
    }

    /// 目前畫的段落。
    public private(set) var paragraphs: [CaptionParagraph] = []
    /// 還在更新（左邊畫綠線）的是哪幾段。
    public private(set) var updating: Set<Int> = []

    /// 上一次畫的是哪一份字幕、哪一版，用什麼選項，標記了哪幾行。
    private var board: UUID?
    private var revision = 0
    private var options: CaptionZoneOptions?
    private var marked: Set<Int> = []
    /// 畫了幾行字幕（不含正在說的那一段）。
    private var lineCount = 0
    /// 每一段（不含自成一段的正在說的那一段）從第幾行開始。
    private var starts: [Int] = []

    public init() {}

    /// 算出要怎麼改，才會變成 `board` 現在的樣子，並記住改完的樣子。
    public mutating func update(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions) -> [Edit] {
        var edits: [Edit] = []
        var from: Int
        if board.identity != self.board || options != self.options {
            if !paragraphs.isEmpty { truncate(0, &edits) }
            self.board = board.identity
            self.options = options
            lineCount = 0
            starts = []
            from = 0
        } else {
            from = min(board.firstChangedLine(since: revision) ?? lineCount, lineCount)
            // 標記有變的行（通常是最後一行）。沒變的時候兩邊是同一份集合，比較只花固定的時間
            if marked != self.marked {
                for id in marked.symmetricDifference(self.marked) {
                    if let index = board.index(ofLine: id) { from = min(from, index) }
                }
            }
        }
        revision = board.revision
        self.marked = marked

        // 從改到的那一行所在的段開始重算。前一段也重算（改到的行可能併進前一句），最後一段一定重算（正在說的那一段可能接在它後面）
        var group = Self.group(containing: from, starts: starts, lineCount: lineCount)
        group = max(0, group - 1)
        let lines = board.lines
        var index = group < starts.count ? starts[group] : 0
        starts.removeLast(starts.count - min(group, starts.count))
        let merges = Self.liveMerges(board)
        while index < lines.count {
            let end = Self.groupEnd(lines, from: index)
            let paragraph = Self.paragraph(
                for: lines[index..<end], board: board, live: merges && end == lines.count, marked: marked, options: options)
            let position = starts.count
            starts.append(index)
            // 內容一樣就不動（例如原本正在說的那一段，剛好和確定之後的那一行一樣）
            if position >= paragraphs.count || paragraphs[position] != paragraph { set(position, paragraph, &edits) }
            index = end
        }
        lineCount = lines.count

        let groups = starts.count
        if !merges, let live = Self.liveParagraph(of: board, options: options) {
            if groups >= paragraphs.count || paragraphs[groups] != live { set(groups, live, &edits) }
            if paragraphs.count > groups + 1 { truncate(groups + 1, &edits) }
        } else if paragraphs.count > groups {
            truncate(groups, &edits)
        }
        return edits
    }

    /// 從頭建立這一區的所有段落。
    public static func paragraphs(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions) -> [CaptionParagraph] {
        let lines = board.lines
        let merges = liveMerges(board)
        var paragraphs: [CaptionParagraph] = []
        var index = 0
        while index < lines.count {
            let end = groupEnd(lines, from: index)
            paragraphs.append(
                paragraph(for: lines[index..<end], board: board, live: merges && end == lines.count, marked: marked, options: options))
            index = end
        }
        if !merges, let live = liveParagraph(of: board, options: options) { paragraphs.append(live) }
        return paragraphs
    }

    /// 最後 `count` 段（浮動字幕用）：和 `paragraphs(board:marked:options:)` 的最後幾段相同，只看最後幾行。
    public static func lastParagraphs(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions, count: Int)
        -> [CaptionParagraph]
    {
        guard count > 0 else { return [] }
        let lines = board.lines
        let merges = liveMerges(board)
        var reversed: [CaptionParagraph] = []
        if !merges, let live = liveParagraph(of: board, options: options) { reversed.append(live) }
        var end = lines.count
        while end > 0, reversed.count < count {
            let start = groupStart(lines, endingAt: end - 1)
            reversed.append(
                paragraph(for: lines[start..<end], board: board, live: merges && end == lines.count, marked: marked, options: options))
            end = start
        }
        return reversed.reversed()
    }

    // MARK: 一段的內容

    /// 一段（一行，或整句模式下同一句的幾行）在這一區顯示什麼。
    ///
    /// 中文區：有整句定稿顯示整句定稿；一句的每一行都確定不會有定稿時，顯示英文並標示「未翻譯」；
    /// 其他的還在等：各行的定稿（沒有時，允許的話是暫定譯文）接起來，都沒有時是「…」。
    /// 英文區：各行的英文接起來；正在說的那一段接在後面時，整段還在更新。
    private static func paragraph(
        for group: ArraySlice<CaptionBoard.Line>, board: CaptionBoard, live: Bool, marked: Set<Int>, options: CaptionZoneOptions
    ) -> CaptionParagraph {
        if group.count == 1, let line = group.first, line.sentence == nil {
            return trimmed(paragraph(for: line, marked: marked.contains(line.id), options: options), options)
        }
        let flagged = options.showsFlags && group.contains { marked.contains($0.id) }
        switch options.language {
        case .english:
            var parts = group.map(\.english)
            if live { parts.append(board.liveEnglish) }
            return CaptionParagraph(text: TextFlow.join(parts), kind: live ? .updating : .settled, flagged: flagged)
        case .chinese:
            if !live, let final = group.last(where: { !$0.sentenceChinese.isEmpty })?.sentenceChinese {
                return trimmed(CaptionParagraph(text: final, kind: .settled, flagged: flagged), options)
            }
            // 整句的暫定譯文：這一句還沒有整句定稿，顯示它（取代各段自己的定稿與逐段的暫定譯文）
            if options.showsProvisional, let sentence = group.first?.sentence, let draft = board.draft(for: sentence),
                !group.contains(where: \.coveredBySentence)
            {
                return trimmed(CaptionParagraph(text: draft.text, kind: .updating, flagged: flagged), options)
            }
            if !live, group.allSatisfy(\.untranslated) {
                return CaptionParagraph(text: TextFlow.join(group.map(\.english)), kind: .untranslated, flagged: flagged)
            }
            var parts = group.map { $0.chinese.isEmpty ? (options.showsProvisional ? $0.provisional : "") : $0.chinese }
            if live, options.showsProvisional { parts.append(board.liveChinese) }
            let text = TextFlow.join(parts)
            return trimmed(CaptionParagraph(text: text.isEmpty ? "…" : text, kind: .updating, flagged: flagged), options)
        }
    }

    /// 一行字幕（沒有句子編號）在這一區顯示什麼。
    ///
    /// 中文區：有定稿顯示定稿；確定不會有定稿時先顯示英文並標示「未翻譯」；
    /// 其他的還在等定稿：允許時顯示暫定譯文，沒有時是「…」。英文區：英文。
    private static func paragraph(for line: CaptionBoard.Line, marked: Bool, options: CaptionZoneOptions)
        -> CaptionParagraph
    {
        let flagged = marked && options.showsFlags
        switch options.language {
        case .english:
            return CaptionParagraph(text: line.english, kind: .settled, flagged: flagged)
        case .chinese:
            if !line.chinese.isEmpty { return CaptionParagraph(text: line.chinese, kind: .settled, flagged: flagged) }
            if line.untranslated { return CaptionParagraph(text: line.english, kind: .untranslated, flagged: flagged) }
            let provisional = options.showsProvisional ? line.provisional : ""
            return CaptionParagraph(text: provisional.isEmpty ? "…" : provisional, kind: .updating, flagged: flagged)
        }
    }

    /// 正在說的那一段自成一段時的內容：英文區是目前的英文（去掉前後的空白）；中文區是它的暫定譯文（允許時）。沒有時是 nil。
    private static func liveParagraph(of board: CaptionBoard, options: CaptionZoneOptions) -> CaptionParagraph? {
        switch options.language {
        case .english:
            let text = board.liveEnglish.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : CaptionParagraph(text: text, kind: .updating, flagged: false)
        case .chinese:
            if options.showsProvisional, let sentence = board.liveSentence, let draft = board.draft(for: sentence) {
                return trimmed(CaptionParagraph(text: draft.text, kind: .updating, flagged: false), options)
            }
            guard options.showsProvisional, !board.liveChinese.isEmpty else { return nil }
            return trimmed(CaptionParagraph(text: board.liveChinese, kind: .updating, flagged: false), options)
        }
    }

    /// 正在說的那一段屬於最後一行的那一句，而且那一句還沒有整句定稿：接在那一句的段落後面。
    private static func liveMerges(_ board: CaptionBoard) -> Bool {
        guard let sentence = board.liveSentence, let last = board.lines.last, last.sentence == sentence,
            !last.coveredBySentence
        else { return false }
        return !board.liveEnglish.trimmingCharacters(in: .whitespaces).isEmpty || !board.liveChinese.isEmpty
    }

    /// 中文區不顯示句尾的「。」時，拿掉最後一個（後面可以跟著引號或括號，例如「好。」）。沒翻到的段落顯示英文，不動。
    private static func trimmed(_ paragraph: CaptionParagraph, _ options: CaptionZoneOptions) -> CaptionParagraph {
        guard options.hidesFinalPeriod, options.language == .chinese, paragraph.kind != .untranslated else { return paragraph }
        var index = paragraph.text.endIndex
        while index > paragraph.text.startIndex {
            let previous = paragraph.text.index(before: index)
            let character = paragraph.text[previous]
            if character == "。" {
                var result = paragraph
                result.text = String(paragraph.text[..<previous]) + String(paragraph.text[index...])
                return result
            }
            guard closingMarks.contains(character) else { break }
            index = previous
        }
        return paragraph
    }

    private static let closingMarks: Set<Character> = ["」", "』", "”", "’", "）", ")", "】", "》", "\"", "'"]

    // MARK: 段與行

    /// 從第 `start` 行開始的這一段到哪一行為止（不含）：沒有句子編號時一行一段，否則是同一句的連續幾行。
    private static func groupEnd(_ lines: [CaptionBoard.Line], from start: Int) -> Int {
        guard let sentence = lines[start].sentence else { return start + 1 }
        var end = start + 1
        while end < lines.count, lines[end].sentence == sentence { end += 1 }
        return end
    }

    /// 以第 `last` 行結束的這一段從哪一行開始。
    private static func groupStart(_ lines: [CaptionBoard.Line], endingAt last: Int) -> Int {
        guard let sentence = lines[last].sentence else { return last }
        var start = last
        while start > 0, lines[start - 1].sentence == sentence { start -= 1 }
        return start
    }

    /// 第 `line` 行在第幾段；這一行還沒畫過時是最後一段。
    private static func group(containing line: Int, starts: [Int], lineCount: Int) -> Int {
        guard !starts.isEmpty else { return 0 }
        guard line < lineCount else { return starts.count - 1 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= line { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private mutating func set(_ index: Int, _ paragraph: CaptionParagraph, _ edits: inout [Edit]) {
        if index < paragraphs.count { paragraphs[index] = paragraph } else { paragraphs.append(paragraph) }
        if paragraph.kind == .updating { updating.insert(index) } else { updating.remove(index) }
        edits.append(.set(index, paragraph))
    }

    private mutating func truncate(_ index: Int, _ edits: inout [Edit]) {
        paragraphs.removeLast(paragraphs.count - index)
        updating = updating.filter { $0 < index }
        edits.append(.truncate(index))
    }
}
