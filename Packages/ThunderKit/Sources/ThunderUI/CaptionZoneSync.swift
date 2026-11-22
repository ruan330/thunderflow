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

    public init(language: Language, showsProvisional: Bool, showsFlags: Bool) {
        self.language = language
        self.showsProvisional = showsProvisional
        self.showsFlags = showsFlags
    }
}

/// 一區字幕畫了什麼，以及下一次要怎麼改。
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

    public init() {}

    /// 算出要怎麼改，才會變成 `board` 現在的樣子。
    public mutating func update(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions) -> [Edit] {
        []
    }

    /// 從頭建立這一區的所有段落。
    public static func paragraphs(board: CaptionBoard, marked: Set<Int>, options: CaptionZoneOptions) -> [CaptionParagraph] {
        []
    }
}
