import Foundation

/// 一區字幕的每一段在一份文字（例如 `NSTextStorage`）裡的位置（UTF-16）。
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

    public init(headerLength: Int) {
        self.headerLength = headerLength
        totalLength = headerLength
    }

    /// 有幾段（不含標題）。
    public var count: Int { 0 }

    /// 第 `index` 段的文字（不含前面的換行）在哪裡。
    public func range(of index: Int) -> Range<Int> {
        0..<0
    }

    /// 第 `index` 段換成長度 `length` 的新內容；`index` 等於目前的段數時加在最後。
    public mutating func set(_ index: Int, length: Int) -> Change {
        Change(range: 0..<0, insertsSeparator: false)
    }

    /// 刪掉第 `index` 段以及之後的所有段。
    public mutating func truncate(_ index: Int) -> Change {
        Change(range: 0..<0, insertsSeparator: false)
    }
}
