import Foundation

/// 逐字稿的一個段落：把相鄰的幾段合起來的英文，加上對應的中文。`blocks.jsonl` 的一行。
///
/// 檔案格式（一行一段，欄位順序固定，文字以 UTF-8 原文存放）：
///
///     {"id":0,"start":10.5,"en":"So today…","zh":"今天…","segments":[0,1,2],"marked":false}
///
/// 讀檔時 `id`、`start`、`en` 是必要欄位，其餘缺少時用預設值，不認識的欄位忽略。
public struct TranscriptBlock: Sendable, Equatable, Codable, Identifiable {
    /// 第幾個段落，從 0 開始。
    public var id: Int
    /// 開始時間（音訊時間，秒）：第一個字出現的時間減 2 秒，四捨五入到毫秒；不小於 0，也不會比前一個段落早。
    public var start: Double
    public var en: String
    /// 這個段落的中文。一段都沒翻到時是空字串。
    public var zh: String
    /// 這個段落包含的段號，依出現的順序。
    public var segments: [Int]
    /// 有重點標記落在這個段落。
    public var marked: Bool

    public init(id: Int, start: Double, en: String, zh: String = "", segments: [Int] = [], marked: Bool = false) {
        self.id = id
        self.start = start
        self.en = en
        self.zh = zh
        self.segments = segments
        self.marked = marked
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, en, zh, segments, marked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(Int.self, forKey: .id),
            start: try container.decode(Double.self, forKey: .start),
            en: try container.decode(String.self, forKey: .en),
            zh: try container.decodeIfPresent(String.self, forKey: .zh) ?? "",
            segments: try container.decodeIfPresent([Int].self, forKey: .segments) ?? [],
            marked: try container.decodeIfPresent(Bool.self, forKey: .marked) ?? false)
    }
}

/// 基本段落（DESIGN.md 5.7.1 節）：從日誌建立段落，以及 `blocks.jsonl` 的讀寫。
public enum TranscriptBlocks {
    public struct BuildResult: Sendable, Equatable {
        public var blocks: [TranscriptBlock]
        /// 有英文、但沒有中文定稿的段數（翻譯失敗，或還沒翻完就結束）。
        public var untranslatedSegments: Int

        public init(blocks: [TranscriptBlock] = [], untranslatedSegments: Int = 0) {
            self.blocks = blocks
            self.untranslatedSegments = untranslatedSegments
        }
    }

    /// 段落滿這麼久（秒）之後，遇到句尾或停頓就結束。
    private static let minimumDuration = 20.0
    /// 段落最長這麼久（秒）。
    private static let maximumDuration = 60.0
    /// 兩段之間隔了這麼久（秒）算一次停頓。
    private static let silenceThreshold = 2.0
    /// 段落的時間比第一個字出現的時間早這麼多（秒）。
    private static let leadIn = 2.0

    /// 把日誌裡的字幕整理成段落。同樣的日誌一定得到同樣的結果。
    ///
    /// **段**
    /// - 有段號的紀錄：同一個段號是同一段。英文以最後一筆 `end` 為 true 的紀錄為準（它帶的是整段的完整文字，
    ///   之前的增量文字只是過程）；中文以同段號最後一筆 `end` 為 true 的紀錄為準。
    /// - 日誌結尾的一段只有增量文字、沒有 `end`（錄音中當掉）：把增量文字接起來當成這一段的英文。
    /// - 已經確定的一段又送來一筆 `end`（補上晚到的標點或尾巴）時，比它晚、還沒確定的段先前累積的增量文字作廢：
    ///   晚到的尾巴原本是當成下一段的增量文字送出的，併回上一段之後下一段重新開始。
    /// - 沒有段號的紀錄（不分段的引擎、加入段號之前的日誌）：每一筆 `end` 為 true 的英文自成一段，
    ///   中文依出現的順序配對；段號從 0 開始依序編。
    /// - 沒有英文的段不進段落；有英文、沒有中文的段照樣進段落（中文留空），並計入 `untranslatedSegments`。
    ///
    /// **段落**：依出現的順序，把相鄰的段合起來——
    /// - 段落滿 20 秒之後，在句尾（`.` `?` `!` `。` `？` `！`，後面可以跟著引號或括號）結束；
    /// - 段落滿 20 秒之後，下一段在 2 秒以上的停頓之後才開始，也結束；
    /// - 加上下一段會超過 60 秒時，先結束；
    /// - 使用者暫停一定結束當時的段落。
    ///
    /// 段落的長度從它第一個字出現的時間算到最後一個字出現的時間。一段的第一個字是它第一筆紀錄的時間，
    /// 最後一個字是它最後一筆增量文字的時間（沒有增量文字時是第一筆 `end` 的時間；補標點的時間不算）。
    /// 暫停與重點標記都用音訊時間判斷，不看它們在日誌裡的位置（它們和字幕由不同的執行緒寫入，先後不固定）。
    ///
    /// **文字**：英文以空白相接；中文直接相接，只有在兩邊都是英數字、或一邊是中文字另一邊是英數字時補一個空白。
    /// 文字裡的換行會收成一行。
    ///
    /// **時間**：`start` 是段落第一個字出現的時間減 2 秒（轉錄服務不給時間戳，字比聲音晚出現；
    /// 點擊跳轉時寧可早一點開始），四捨五入到毫秒，不小於 0，也不會比前一個段落早。
    ///
    /// **重點標記**：標在「標記當下，第一個字已經出現的最後一個段落」；比所有段落都早的標記算在第一個段落。
    public static func build(from entries: [JournalEntry]) -> BuildResult {
        let journal = collect(entries)
        var blocks: [TranscriptBlock] = []
        /// 每個段落第一個字出現的時間（沒有減 2 秒），用來判斷重點標記落在哪裡。
        var firstWordTimes: [Double] = []
        var current: [Segment] = []

        func closeBlock() {
            guard let first = current.first else { return }
            var start = (max(0, first.start - leadIn) * 1_000).rounded() / 1_000
            if let previous = blocks.last { start = max(start, previous.start) }
            blocks.append(
                TranscriptBlock(
                    id: blocks.count, start: start, en: TextFlow.join(current.map(\.en)),
                    zh: TextFlow.join(current.map(\.zh)), segments: current.map(\.number), marked: false))
            firstWordTimes.append(first.start)
            current = []
        }

        for segment in journal.segments {
            if let first = current.first, let last = current.last {
                let paused = journal.pauses.contains { last.start <= $0 && $0 < segment.start }
                let tooLong = segment.end - first.start > maximumDuration
                let afterSilence =
                    segment.start - last.end >= silenceThreshold && last.end - first.start >= minimumDuration
                if paused || tooLong || afterSilence { closeBlock() }
            }
            current.append(segment)
            if let first = current.first, segment.end - first.start >= minimumDuration, endsSentence(segment.en) {
                closeBlock()
            }
        }
        closeBlock()

        for mark in journal.marks where !blocks.isEmpty {
            let index = firstWordTimes.lastIndex { $0 <= mark } ?? 0
            blocks[index].marked = true
        }
        return BuildResult(blocks: blocks, untranslatedSegments: journal.segments.count { $0.zh.isEmpty })
    }

    /// 讀取 `blocks.jsonl`：一行一個 JSON 物件。
    ///
    /// 讀不懂的行會跳過，所以最後一行寫到一半也不影響前面的段落；最後一行沒有換行但內容完整時照樣採用。
    /// 檔案不存在則丟出錯誤。
    public static func read(_ url: URL) throws -> [TranscriptBlock] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(TranscriptBlock.self, from: line)
        }
    }

    /// 原子寫入 `blocks.jsonl`（先寫暫存檔再改名）：讀的人只會看到舊的完整內容或新的完整內容。
    /// 同樣的段落每次寫出來的位元組都一樣。
    public static func write(_ blocks: [TranscriptBlock], to url: URL) throws {
        var bytes: [UInt8] = []
        for block in blocks { BlockLine.append(block, to: &bytes) }
        try FileIO.writeAtomically(Data(bytes), to: url)
    }
}

// MARK: 從日誌整理出段

extension TranscriptBlocks {
    /// 整理好的一段：英文、它的中文，以及第一個字與最後一個字出現的時間。
    private struct Segment {
        var number: Int
        var start: Double
        var end: Double
        var en: String
        var zh: String
    }

    /// 還在收集中的一段。
    private struct Draft {
        /// 日誌裡的段號；沒有段號的紀錄是 nil。
        var number: Int?
        var firstTextAt: Double?
        var lastTextAt = 0.0
        /// 還沒確定之前累積的增量文字。
        var deltas = ""
        /// 最後一筆 `end` 為 true 的文字。
        var finalText: String?

        mutating func noteText(at time: Double) {
            if firstTextAt == nil {
                firstTextAt = time
                lastTextAt = time
            } else {
                lastTextAt = max(lastTextAt, time)
            }
        }
    }

    private struct Collected {
        var segments: [Segment] = []
        var pauses: [Double] = []
        var marks: [Double] = []
    }

    private static func collect(_ entries: [JournalEntry]) -> Collected {
        var collected = Collected()
        /// 依第一次出現的順序。
        var drafts: [Draft] = []
        var indexByNumber: [Int: Int] = [:]
        /// 沒有段號的段：在 `drafts` 裡的位置，依出現的順序；最後一個可能還沒結束。
        var unnumbered: [Int] = []
        var unnumberedIsOpen = false
        var translations: [Int: String] = [:]
        var unnumberedTranslations: [String] = []

        for entry in entries {
            switch entry {
            case .source(let text):
                let index: Int
                if let number = text.segment {
                    if let known = indexByNumber[number] {
                        index = known
                    } else {
                        index = drafts.count
                        indexByNumber[number] = index
                        drafts.append(Draft(number: number))
                    }
                } else if unnumberedIsOpen, let open = unnumbered.last {
                    index = open
                } else {
                    index = drafts.count
                    unnumbered.append(index)
                    unnumberedIsOpen = true
                    drafts.append(Draft(number: nil))
                }
                switch text.kind {
                case .delta:
                    // 已經確定的段之後又來的增量文字不採用：以最後一筆 end 為準
                    guard drafts[index].finalText == nil else { break }
                    drafts[index].deltas += text.text
                    drafts[index].noteText(at: text.at.seconds)
                case .segmentEnd:
                    if drafts[index].firstTextAt == nil { drafts[index].noteText(at: text.at.seconds) }
                    drafts[index].finalText = text.text
                    if text.segment == nil {
                        unnumberedIsOpen = false
                    } else {
                        discardPendingDeltas(after: index, in: &drafts)
                    }
                }
            case .translation(let text):
                guard text.kind == .segmentEnd else { break }
                if let number = text.segment {
                    translations[number] = text.text
                } else {
                    unnumberedTranslations.append(text.text)
                }
            case .marker(let time):
                collected.marks.append(time.seconds)
            case .paused(let time):
                collected.pauses.append(time.seconds)
            case .gap, .resumed:
                break
            }
        }

        // 沒有段號的段接在最大的段號後面依序編號，不會和有段號的段撞號
        let firstFreeNumber = (indexByNumber.keys.max() ?? -1) + 1
        var ordinalByIndex: [Int: Int] = [:]
        for (ordinal, index) in unnumbered.enumerated() { ordinalByIndex[index] = ordinal }

        for (index, draft) in drafts.enumerated() {
            let en = TextFlow.singleLine(draft.finalText ?? draft.deltas)
            guard !en.isEmpty, let start = draft.firstTextAt else { continue }
            let number: Int
            let translation: String?
            if let explicit = draft.number {
                number = explicit
                translation = translations[explicit]
            } else {
                let ordinal = ordinalByIndex[index] ?? 0
                number = firstFreeNumber + ordinal
                translation = ordinal < unnumberedTranslations.count ? unnumberedTranslations[ordinal] : nil
            }
            collected.segments.append(
                Segment(
                    number: number, start: start, end: draft.lastTextAt, en: en,
                    zh: TextFlow.singleLine(translation ?? "")))
        }
        return collected
    }

    /// 第 `index` 段又確定了一次（補上晚到的標點或尾巴）：比它晚、還沒確定的段，先前累積的增量文字作廢。
    ///
    /// 晚到的尾巴是先當成下一段的增量文字送出、再併回這一段的，所以那些字出現的時間算在這一段。
    private static func discardPendingDeltas(after index: Int, in drafts: inout [Draft]) {
        var later = index + 1
        while later < drafts.count {
            if drafts[later].number != nil, drafts[later].finalText == nil, drafts[later].firstTextAt != nil {
                if drafts[later].deltas.contains(where: { $0.isLetter || $0.isNumber }) {
                    drafts[index].lastTextAt = max(drafts[index].lastTextAt, drafts[later].lastTextAt)
                }
                drafts[later].deltas = ""
                drafts[later].firstTextAt = nil
                drafts[later].lastTextAt = 0
            }
            later += 1
        }
    }

    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
    /// 跟在句尾標點後面、仍然屬於同一句的引號與括號。
    private static let sentenceClosers: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "}", "」", "』", "）", "】", "》",
    ]

    private static func endsSentence(_ text: String) -> Bool {
        var remaining = Substring(text)
        while let last = remaining.last, sentenceClosers.contains(last) || last.isWhitespace {
            remaining.removeLast()
        }
        return remaining.last.map(sentenceTerminators.contains) ?? false
    }
}

/// 把一個段落排成 `blocks.jsonl` 的一行（含結尾的換行）。
///
/// 和日誌一樣不用 `JSONEncoder`：欄位照固定的順序輸出，文字以 UTF-8 原文存放（搜尋直接掃描位元組），
/// 只跳脫 JSON 規定必須跳脫的字元。
private enum BlockLine {
    static func append(_ block: TranscriptBlock, to line: inout [UInt8]) {
        line.append(contentsOf: #"{"id":"#.utf8)
        line.append(contentsOf: String(block.id).utf8)
        line.append(contentsOf: #","start":"#.utf8)
        line.append(contentsOf: number(block.start).utf8)
        line.append(contentsOf: #","en":"#.utf8)
        appendString(block.en, to: &line)
        line.append(contentsOf: #","zh":"#.utf8)
        appendString(block.zh, to: &line)
        line.append(contentsOf: #","segments":["#.utf8)
        line.append(contentsOf: block.segments.map(String.init).joined(separator: ",").utf8)
        line.append(contentsOf: #"],"marked":"#.utf8)
        line.append(contentsOf: (block.marked ? "true" : "false").utf8)
        line.append(contentsOf: "}\n".utf8)
    }

    /// 整數值寫成整數（`34` 而不是 `34.0`），其他寫成能精確讀回的最短十進位表示；不是有限的數字寫成 0。
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return value.description
    }

    private static func appendString(_ string: String, to line: inout [UInt8]) {
        line.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): line.append(contentsOf: #"\""#.utf8)
            case UInt8(ascii: "\\"): line.append(contentsOf: #"\\"#.utf8)
            case UInt8(ascii: "\n"): line.append(contentsOf: #"\n"#.utf8)
            case UInt8(ascii: "\r"): line.append(contentsOf: #"\r"#.utf8)
            case UInt8(ascii: "\t"): line.append(contentsOf: #"\t"#.utf8)
            case 0x00..<0x20:
                // 其餘的控制字元 JSON 規定一定要跳脫
                let hex = Array("0123456789abcdef".utf8)
                line.append(contentsOf: #"\u00"#.utf8)
                line.append(hex[Int(byte >> 4)])
                line.append(hex[Int(byte & 0x0F)])
            default:
                line.append(byte)
            }
        }
        line.append(UInt8(ascii: "\""))
    }
}
