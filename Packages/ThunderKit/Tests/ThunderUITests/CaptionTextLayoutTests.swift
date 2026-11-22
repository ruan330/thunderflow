import Foundation
import Testing
import ThunderUI

/// 照著 `Change` 改一份 UTF-16 的文字，和畫面改 `NSTextStorage` 的做法一樣。
private func apply(_ change: CaptionTextLayout.Change, content: [UInt16], to text: inout [UInt16]) {
    let replacement = (change.insertsSeparator ? Array("\n".utf16) : []) + content
    text.replaceSubrange(change.range, with: replacement)
}

@Suite("字幕區的文字位置：每一段在文字裡的哪裡")
struct CaptionTextLayoutTests {
    @Test("第一段加在標題後面，前面先加一個換行")
    func firstParagraph() {
        var layout = CaptionTextLayout(headerLength: 2)
        #expect(layout.totalLength == 2)
        let change = layout.set(0, length: 5)
        #expect(change == CaptionTextLayout.Change(range: 2..<2, insertsSeparator: true))
        #expect(layout.totalLength == 8)
        #expect(layout.count == 1)
        #expect(layout.range(of: 0) == 3..<8)
    }

    @Test("換掉中間的一段：只取代那一段的文字，前後的換行不動")
    func replaceMiddle() {
        var layout = CaptionTextLayout(headerLength: 2)
        for length in [5, 3, 4] { _ = layout.set(layout.count, length: length) }
        // 標題 0..<2，換行，第 0 段 3..<8，換行，第 1 段 9..<12，換行，第 2 段 13..<17
        #expect(layout.range(of: 1) == 9..<12)
        let change = layout.set(1, length: 6)
        #expect(change == CaptionTextLayout.Change(range: 9..<12, insertsSeparator: false))
        #expect(layout.range(of: 2) == 16..<20)
        #expect(layout.totalLength == 20)
    }

    @Test("加在最後：前面先加一個換行")
    func append() {
        var layout = CaptionTextLayout(headerLength: 2)
        for length in [5, 3] { _ = layout.set(layout.count, length: length) }
        let change = layout.set(2, length: 2)
        #expect(change == CaptionTextLayout.Change(range: 12..<12, insertsSeparator: true))
        #expect(layout.range(of: 2) == 13..<15)
    }

    @Test("從第幾段刪起：連同它前面的換行一起刪；全部刪掉時只剩標題")
    func truncate() {
        var layout = CaptionTextLayout(headerLength: 2)
        for length in [5, 3, 4] { _ = layout.set(layout.count, length: length) }
        #expect(layout.truncate(1) == CaptionTextLayout.Change(range: 8..<17, insertsSeparator: false))
        #expect(layout.count == 1)
        #expect(layout.totalLength == 8)
        #expect(layout.truncate(0) == CaptionTextLayout.Change(range: 2..<8, insertsSeparator: false))
        #expect(layout.totalLength == 2)
        #expect(layout.truncate(0) == CaptionTextLayout.Change(range: 2..<2, insertsSeparator: false))
    }

    @Test("一長串修改（大多在最後幾段，偶爾很前面）：文字和每一段的位置都和從頭排的一樣")
    func randomEdits() throws {
        var random = SplitMix64(seed: 21)
        let header = Array("中文".utf16)
        var layout = CaptionTextLayout(headerLength: header.count)
        var paragraphs: [[UInt16]] = []
        var text = header
        for step in 0..<3_000 {
            let roll = Double.random(in: 0..<1, using: &random)
            if roll < 0.05, !paragraphs.isEmpty {
                let index = Int.random(in: max(0, paragraphs.count - 3)...paragraphs.count, using: &random)
                apply(layout.truncate(index), content: [], to: &text)
                paragraphs.removeLast(paragraphs.count - index)
            } else {
                // 一成改到很前面的段，其他改最後三段或加一段
                let lowest = roll < 0.15 ? 0 : max(0, paragraphs.count - 3)
                let index = Int.random(in: lowest...paragraphs.count, using: &random)
                let content = Array("第\(step)段".utf16) + Array(repeating: 0x61, count: Int.random(in: 0...20, using: &random))
                apply(layout.set(index, length: content.count), content: content, to: &text)
                if index == paragraphs.count { paragraphs.append(content) } else { paragraphs[index] = content }
            }
            #expect(layout.count == paragraphs.count)
        }
        try #require(paragraphs.count > 10)
        let expected = paragraphs.reduce(header) { $0 + Array("\n".utf16) + $1 }
        #expect(text == expected)
        #expect(layout.totalLength == expected.count)
        var location = header.count
        for (index, paragraph) in paragraphs.enumerated() {
            location += 1
            #expect(layout.range(of: index) == location..<(location + paragraph.count))
            location += paragraph.count
        }
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
