import Foundation
import ThunderCore

/// 字幕畫面的內容：已經確定的每一段（一行），加上正在說的那一段。
///
/// 純資料，不碰畫面：把引擎的事件一個一個套上去（`apply`），畫面照著 `lines`、`liveEnglish`、`liveChinese` 畫。
/// 英文和它的中文用段號配對（DESIGN.md 5.6.1 節），所以中文定稿比下一段英文晚到，也會出現在自己那一行。
///
/// 每一次改到 `lines` 都記一版（`revision`）。畫面記住自己畫到哪一版，下一次用 `firstChangedLine(since:)`
/// 問從哪一行開始要重畫，不必每次比對整份字幕（DESIGN.md 9.8 節：每次更新的成本不隨場次變長）。
/// 兩份字幕的內容一樣就相等，不看版本與識別。
public struct CaptionBoard: Sendable, Equatable {
    /// 已經確定的一段。
    public struct Line: Sendable, Equatable, Identifiable {
        /// 段號。
        public var id: Int
        public var english: String
        /// 中文定稿；還沒有時是空字串。
        public var chinese: String
        /// 定稿到之前先顯示的暫定譯文；定稿到了就清掉，不再出現。
        public var provisional: String
        /// 確定不會有定稿了（翻譯失敗，或引擎已經結束）。結束後由精修補上。
        public var untranslated: Bool
        /// 這一段確定時的音訊時間。
        public var at: AudioTime
        /// 整句模式：這一段屬於第幾句（同一句的段在畫面上合成一個段落）。不是整句模式時是 nil。
        public var sentence: Int? = nil
        /// 這一句的整句定稿：只放在這一句的最後一段，其他段是空字串。
        public var sentenceChinese = ""
        /// 這一段屬於一句已經有整句定稿的句子：中文在整句定稿裡，自己沒有定稿也不算沒翻到。
        public var coveredBySentence = false
    }

    public private(set) var lines: [Line] = []
    /// 正在說的那一段的段號。
    public private(set) var liveSegment: Int?
    /// 正在說的那一段目前的英文。
    public private(set) var liveEnglish = ""
    /// 正在說的那一段目前的暫定譯文。
    public private(set) var liveChinese = ""
    /// 整句模式：正在說的那一段屬於第幾句。
    public private(set) var liveSentence: Int?
    /// 暫定譯文屬於哪一段。
    private var liveChineseSegment: Int?

    /// 字幕改過幾版：每一次改到 `lines`（新增一行，或改到已經有的行）就加一。正在說的那一段改變不算。
    public private(set) var revision = 0
    /// 這一份字幕的識別：複製的是同一份，清空重來（`CaptionBoard()`）的是另一份。
    public let identity = UUID()
    /// 最近幾版各自最前面改到的是哪一行（`firstChangedLine(since:)` 用）。只留最近的，太舊的丟掉。
    private var changes: [Change] = []
    /// 至少記得最近幾版。畫面每秒更新最多 30 次，兩次之間通常只有幾版。
    private static let remembered = 256

    private struct Change: Sendable {
        var revision: Int
        var line: Int
    }

    public init() {}

    public static func == (lhs: CaptionBoard, rhs: CaptionBoard) -> Bool {
        lhs.lines == rhs.lines && lhs.liveSegment == rhs.liveSegment && lhs.liveEnglish == rhs.liveEnglish
            && lhs.liveChinese == rhs.liveChinese && lhs.liveChineseSegment == rhs.liveChineseSegment
    }

    /// 從 `revision` 那一版到現在，最前面改到（或新增）的是第幾行；沒有改到任何一行時是 nil。
    ///
    /// 問的版本太舊、紀錄已經丟掉時回傳 0（從頭比對一次）：回答的行只會比真正改到的早，不會晚。
    public func firstChangedLine(since revision: Int) -> Int? {
        guard revision < self.revision else { return nil }
        guard let oldest = changes.first, oldest.revision <= revision + 1 else { return 0 }
        var first = Int.max
        for change in changes.reversed() {
            if change.revision <= revision { break }
            first = min(first, change.line)
        }
        return first
    }

    /// 段號是 `id` 的那一行在 `lines` 裡的位置；沒有這一行時是 nil。從後面找：要找的通常是最近的幾行。
    public func index(ofLine id: Int) -> Int? {
        index(of: id)
    }

    /// 套用一個引擎事件。狀態、缺口、用量不影響字幕，會被忽略。
    public mutating func apply(_ event: CaptionEvent) {
        switch event {
        case .source(let text):
            if text.kind == .delta {
                let segment = text.segment ?? lines.count
                if liveSegment != segment {
                    liveSegment = segment
                    liveEnglish = ""
                }
                liveEnglish += text.text
            } else {
                finishSource(text)
            }
        case .provisional(let text):
            guard let segment = text.segment else { return }
            if let index = index(of: segment) {
                // 這一段的英文已經確定：暫定譯文只在定稿到之前有用
                if lines[index].chinese.isEmpty, lines[index].provisional != text.text {
                    lines[index].provisional = text.text
                    changed(from: index)
                }
            } else {
                liveChineseSegment = segment
                liveChinese = text.text
            }
        case .translation(let text):
            // 沒有段號的引擎：照順序配給第一行還沒有中文的
            guard let index = text.segment.flatMap(index(of:)) ?? lines.firstIndex(where: { $0.chinese.isEmpty && !$0.untranslated })
            else { return }
            lines[index].chinese = text.text
            lines[index].provisional = ""
            lines[index].untranslated = false
            // 定稿依段的順序送出：輪到這一段了，前面還沒有中文的就是沒翻到
            var earlier = index - 1
            while earlier >= 0, lines[earlier].chinese.isEmpty, !lines[earlier].untranslated {
                lines[earlier].untranslated = true
                lines[earlier].provisional = ""
                earlier -= 1
            }
            changed(from: earlier + 1)
        case .status, .gap, .usage:
            break
        }
    }

    /// 引擎結束了：還沒有中文的段不會再有定稿。
    public mutating func engineEnded() {
        var first: Int?
        for index in lines.indices where lines[index].chinese.isEmpty {
            guard !lines[index].untranslated || !lines[index].provisional.isEmpty else { continue }
            lines[index].untranslated = true
            lines[index].provisional = ""
            if first == nil { first = index }
        }
        if let first { changed(from: first) }
        liveChinese = ""
        liveChineseSegment = nil
    }

    /// 這一行要顯示的中文：有定稿用定稿；沒有的話，允許時顯示暫定譯文。
    public func chinese(for line: Line, showingProvisional: Bool) -> String {
        if !line.chinese.isEmpty { return line.chinese }
        return showingProvisional ? line.provisional : ""
    }

    private mutating func finishSource(_ text: CaptionText) {
        let segment = text.segment ?? lines.count
        if let index = index(of: segment) {
            // 同一段再確定一次：補上了晚到的標點或尾巴，以這一次為準
            lines[index].english = text.text
            changed(from: index)
        } else {
            let carried = liveChineseSegment == segment ? liveChinese : ""
            lines.append(Line(id: segment, english: text.text, chinese: "", provisional: carried, untranslated: false, at: text.at))
            changed(from: lines.count - 1)
        }
        // 進行中的那一行到此為止（它不是剛確定的這一段，就是被併進上一段的尾巴）
        liveEnglish = ""
        liveSegment = nil
        if liveChineseSegment == nil || liveChineseSegment == segment || liveChineseSegment == segment + 1 {
            liveChinese = ""
            liveChineseSegment = nil
        }
    }

    /// 記一版：這一版從第 `line` 行開始有改變。
    private mutating func changed(from line: Int) {
        revision += 1
        changes.append(Change(revision: revision, line: line))
        // 累積到兩倍才丟掉前面的：平均每一版只花固定的時間
        if changes.count >= 2 * Self.remembered { changes.removeFirst(changes.count - Self.remembered) }
    }

    /// 第 `segment` 段在 `lines` 裡的位置。段是依序加進去的，最近的幾段在最後面，所以從後面找。
    private func index(of segment: Int) -> Int? {
        var index = lines.count - 1
        while index >= 0 {
            if lines[index].id == segment { return index }
            if lines[index].id < segment { return nil }
            index -= 1
        }
        return nil
    }
}
