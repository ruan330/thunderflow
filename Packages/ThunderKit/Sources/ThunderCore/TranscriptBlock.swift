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
        // 尚未實作（M3）
        BuildResult()
    }

    /// 讀取 `blocks.jsonl`：一行一個 JSON 物件。
    ///
    /// 讀不懂的行會跳過，所以最後一行寫到一半也不影響前面的段落；最後一行沒有換行但內容完整時照樣採用。
    /// 檔案不存在則丟出錯誤。
    public static func read(_ url: URL) throws -> [TranscriptBlock] {
        // 尚未實作（M3）
        []
    }

    /// 原子寫入 `blocks.jsonl`（先寫暫存檔再改名）：讀的人只會看到舊的完整內容或新的完整內容。
    /// 同樣的段落每次寫出來的位元組都一樣。
    public static func write(_ blocks: [TranscriptBlock], to url: URL) throws {
        // 尚未實作（M3）
    }
}
