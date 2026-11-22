import Foundation

/// 把幾段文字接成一段、把多行收成一行。段落的英文與中文、摘要裡的字串、整句定稿的備用譯文都用它。
public enum TextFlow {
    /// 去掉頭尾的空白，並把換行收掉：各行依 `join` 的規則相接。
    public static func singleLine(_ text: String) -> String {
        join(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// 依序相接，每一段先去掉頭尾的空白，空的略過。
    ///
    /// 接縫的規則：兩邊都是英數字或半形標點時補一個空白（英文）；中文字和英數字之間也補一個空白
    /// （和文字模型輸出的寫法一致，例如「提供 3 個元件」）；其餘（中文字接中文字、任何一邊是全形標點）直接相連。
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = piece.first else { continue }
            if let last = result.last { result += separator(between: last, and: first) }
            result += piece
        }
        return result
    }

    /// 這段文字以句尾的標點結束（`.` `?` `!` `。` `？` `！`，後面可以跟著引號或括號與空白）。
    /// 基本段落決定段落在哪裡結束、翻譯排程決定一句在哪裡結束，都用這個規則。
    public static func endsSentence(_ text: String) -> Bool {
        var remaining = Substring(text)
        while let last = remaining.last, sentenceClosers.contains(last) || last.isWhitespace {
            remaining.removeLast()
        }
        return remaining.last.map(sentenceTerminators.contains) ?? false
    }

    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
    /// 跟在句尾標點後面、仍然屬於同一句的引號與括號。
    private static let sentenceClosers: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "}", "」", "』", "）", "】", "》",
    ]

    private enum Kind {
        /// 中日韓的文字。
        case wideLetter
        /// 全形標點與符號。
        case widePunctuation
        /// 其他語言的字母與數字。
        case narrowWord
        case other
    }

    private static func separator(between left: Character, and right: Character) -> String {
        switch (kind(left), kind(right)) {
        case (.widePunctuation, _), (_, .widePunctuation): ""
        case (.wideLetter, .wideLetter): ""
        case (.wideLetter, .narrowWord), (.narrowWord, .wideLetter): " "
        case (.wideLetter, .other), (.other, .wideLetter): ""
        default: " "
        }
    }

    private static func kind(_ character: Character) -> Kind {
        guard let value = character.unicodeScalars.first?.value else { return .other }
        switch value {
        case 0x3000...0x303F, 0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF00...0xFFEF:
            return .widePunctuation
        case 0x1100...0x11FF, 0x3040...0x312F, 0x31A0...0x31BF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
            0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .wideLetter
        default:
            return character.isLetter || character.isNumber ? .narrowWord : .other
        }
    }
}
