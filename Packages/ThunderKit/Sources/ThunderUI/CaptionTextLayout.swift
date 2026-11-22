import Foundation

/// 一區字幕的每一段在一份文字（例如 `NSTextStorage`）裡的位置（UTF-16）。
///
/// 文字的排法：開頭是固定的一段（標題，長度 `headerLength`），之後每一段前面有一個換行。
/// 換行放在段的前面而不是後面，文字的最後就不會多出一個空行。
/// 位置從最後面往前算：要改的通常是最後幾段，所以每一次的成本不隨段數變多。
///
/// 每個操作都不會讓程式停下來：超出範圍的位置當成加在最後（`set`）或什麼都不刪（`truncate`）。
/// 字幕畫錯一段，比錄音中的 App 當掉好。
public struct CaptionTextLayout: Sendable, Equatable {
    /// 一次修改落在文字的哪裡。
    public struct Change: Sendable, Equatable {
        /// 要被取代的範圍（UTF-16）。
        public var range: Range<Int>
        /// 新的內容前面要先加一個換行（新增的段）。
        public var insertsSeparator: Bool

        public init(range: Range<Int>, insertsSeparator: Bool) {
            self.range = range
            self.insertsSeparator = insertsSeparator
        }
    }

    /// 開頭固定的那一段（標題）的長度。
    public let headerLength: Int
    /// 整份文字的長度。
    public private(set) var totalLength: Int
    /// 每一段的長度（不含前面的換行）。
    private var lengths: [Int] = []

    public init(headerLength: Int) {
        self.headerLength = headerLength
        totalLength = headerLength
    }

    /// 有幾段（不含標題）。
    public var count: Int { lengths.count }

    /// 第 `index` 段的文字（不含前面的換行）在哪裡。
    public func range(of index: Int) -> Range<Int> {
        guard index >= 0, index < lengths.count else { return totalLength..<totalLength }
        let start = separator(of: index) + 1
        return start..<(start + lengths[index])
    }

    /// 第 `index` 段換成長度 `length` 的新內容；`index` 等於目前的段數時加在最後。
    public mutating func set(_ index: Int, length: Int) -> Change {
        guard index >= 0, index < lengths.count else {
            let end = totalLength
            lengths.append(length)
            totalLength += length + 1
            return Change(range: end..<end, insertsSeparator: true)
        }
        let replaced = range(of: index)
        totalLength += length - lengths[index]
        lengths[index] = length
        return Change(range: replaced, insertsSeparator: false)
    }

    /// 刪掉第 `index` 段以及之後的所有段（連同各段前面的換行）。
    public mutating func truncate(_ index: Int) -> Change {
        let index = max(0, index)
        guard index < lengths.count else { return Change(range: totalLength..<totalLength, insertsSeparator: false) }
        let start = separator(of: index)
        let removed = start..<totalLength
        lengths.removeLast(lengths.count - index)
        totalLength = start
        return Change(range: removed, insertsSeparator: false)
    }

    /// 第 `index` 段前面那個換行的位置。
    private func separator(of index: Int) -> Int {
        var location = totalLength
        var current = lengths.count
        while current > index {
            current -= 1
            location -= lengths[current] + 1
        }
        return location
    }
}
