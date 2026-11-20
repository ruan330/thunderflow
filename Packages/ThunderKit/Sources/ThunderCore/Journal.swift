import Foundation

/// 場次日誌的一筆紀錄。錄音中只追加寫入 `journal.jsonl`，一行一筆 JSON。
///
/// 檔案格式（v1）：
///
///     {"k":"src","t":12.5,"x":"Hello","end":true}     英文；`end` 為 true 表示一句結束，false 時省略
///     {"k":"tr","t":13.25,"x":"你好","end":true}       中文
///     {"k":"gap","from":30,"to":42.5,"why":"network"} 沒翻譯到的音訊
///     {"k":"mark","t":95}                              重點標記
///     {"k":"pause","t":120}                            暫停
///     {"k":"resume","t":120}                           繼續
///
/// `t`、`from`、`to` 都是音訊時間（秒）。文字以 UTF-8 原文存放，不做 \u 跳脫。
public enum JournalEntry: Sendable, Equatable {
    case source(CaptionText)
    case translation(CaptionText)
    case gap(AudioGap)
    case marker(at: AudioTime)
    case paused(at: AudioTime)
    case resumed(at: AudioTime)
}

extension JournalEntry: Codable {
    public init(from decoder: any Decoder) throws {
        throw NotYetImplemented("JournalEntry.init(from:)")
    }

    public func encode(to encoder: any Encoder) throws {
        throw NotYetImplemented("JournalEntry.encode(to:)")
    }
}

/// 讀回來的日誌內容。
public struct JournalContents: Sendable, Equatable {
    public var entries: [JournalEntry]
    /// 檔案最後一行不完整（寫到一半被中斷），已略過。
    public var hasTruncatedTail: Bool
    /// 看不懂而跳過的行數：未知的種類，或不是合法的 JSON。
    public var skippedLineCount: Int

    public init(entries: [JournalEntry] = [], hasTruncatedTail: Bool = false, skippedLineCount: Int = 0) {
        self.entries = entries
        self.hasTruncatedTail = hasTruncatedTail
        self.skippedLineCount = skippedLineCount
    }
}

/// 只追加的日誌寫入器。可以從多條執行緒同時呼叫。
///
/// 每次 `append` 返回時，那一行已經交給作業系統（不留在程式自己的緩衝區），
/// 所以程式被強制結束也不會遺失已經 append 的紀錄。
public final class JournalWriter: @unchecked Sendable {
    /// 開啟日誌檔。檔案不存在就建立；已存在就接在後面寫。
    public init(url: URL) throws {
        throw NotYetImplemented("JournalWriter.init(url:)")
    }

    public func append(_ entry: JournalEntry) throws {
        throw NotYetImplemented("JournalWriter.append(_:)")
    }

    public func close() {}
}

public enum JournalReader {
    /// 讀取日誌。讀不懂的行會跳過並計數，不會讓整個讀取失敗；檔案不存在則丟出錯誤。
    public static func read(_ url: URL) throws -> JournalContents {
        throw NotYetImplemented("JournalReader.read(_:)")
    }
}
