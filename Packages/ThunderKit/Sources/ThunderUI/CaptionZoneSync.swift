import Foundation

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
/// 每一行字幕是一段，最後可能再加上正在說的那一段。這裡記住上一次畫到 `CaptionBoard` 的哪一版，
/// 這一次只比對之後改過的行（`CaptionBoard.firstChangedLine(since:)`）、標記有變的行與正在說的那一段，
/// 算出最少的修改（`Edit`）。畫面照著改，不必整區重畫，也不必拿著整份字幕。
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

        let lines = board.lines
        var index = from
        while index < lines.count {
            let line = lines[index]
            let paragraph = Self.paragraph(for: line, marked: marked.contains(line.id), options: options)
            // 內容一樣就不動（例如原本正在說的那一段，剛好和確定之後的那一行一樣）
            if index >= paragraphs.count || paragraphs[index] != paragraph { set(index, paragraph, &edits) }
            index += 1
        }
        lineCount = lines.count

        if let live = Self.liveParagraph(of: board, options: options) {
            if lineCount >= paragraphs.count || paragraphs[lineCount] != live { set(lineCount, live, &edits) }
            if paragraphs.count > lineCount + 1 { truncate(lineCount + 1, &edits) }
        } else if paragraphs.count > lineCount {
            truncate(lineCount, &edits)
        }
        return edits
    }

    /// 從頭建立這一區的所有段落。
    public static func paragraphs(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions) -> [CaptionParagraph] {
        var paragraphs = board.lines.map { paragraph(for: $0, marked: marked.contains($0.id), options: options) }
        if let live = liveParagraph(of: board, options: options) { paragraphs.append(live) }
        return paragraphs
    }

    /// 最後 `count` 段（浮動字幕用）：和 `paragraphs(board:marked:options:)` 的最後幾段相同，只看最後幾行。
    public static func lastParagraphs(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions, count: Int)
        -> [CaptionParagraph]
    {
        []
    }

    /// 一行字幕在這一區顯示什麼。
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

    /// 正在說的那一段：英文區是目前的英文（去掉前後的空白）；中文區是它的暫定譯文（允許時）。沒有時是 nil。
    private static func liveParagraph(of board: CaptionBoard, options: CaptionZoneOptions) -> CaptionParagraph? {
        switch options.language {
        case .english:
            let text = board.liveEnglish.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : CaptionParagraph(text: text, kind: .updating, flagged: false)
        case .chinese:
            guard options.showsProvisional, !board.liveChinese.isEmpty else { return nil }
            return CaptionParagraph(text: board.liveChinese, kind: .updating, flagged: false)
        }
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
