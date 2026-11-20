import Foundation
import Synchronization

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
/// `why` 是 network／backpressure／engineStopped，讀到不認識的原因會變成 `.unknown`。
public enum JournalEntry: Sendable, Equatable {
    case source(CaptionText)
    case translation(CaptionText)
    case gap(AudioGap)
    case marker(at: AudioTime)
    case paused(at: AudioTime)
    case resumed(at: AudioTime)
}

extension JournalEntry: Codable {
    private enum Key: String, CodingKey {
        case kind = "k", time = "t", text = "x", end, from, to, why
    }

    /// `k` 欄位的值。
    fileprivate enum Kind: String {
        case source = "src", translation = "tr", gap, marker = "mark", paused = "pause", resumed = "resume"
    }

    fileprivate var kind: Kind {
        switch self {
        case .source: .source
        case .translation: .translation
        case .gap: .gap
        case .marker: .marker
        case .paused: .paused
        case .resumed: .resumed
        }
    }

    /// 不認識的種類（例如未來版本新增的紀錄）會丟出 `DecodingError`，讀取端據此跳過那一行。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "不認識的紀錄種類「\(rawKind)」")
        }
        switch kind {
        case .source, .translation:
            let text = CaptionText(
                text: try container.decode(String.self, forKey: .text),
                kind: try container.decodeIfPresent(Bool.self, forKey: .end) == true ? .segmentEnd : .delta,
                at: try container.decode(AudioTime.self, forKey: .time))
            self = kind == .source ? .source(text) : .translation(text)
        case .gap:
            let why = try container.decodeIfPresent(String.self, forKey: .why)
            self = .gap(
                AudioGap(
                    from: try container.decode(AudioTime.self, forKey: .from),
                    to: try container.decode(AudioTime.self, forKey: .to),
                    reason: why.flatMap(GapReason.init(rawValue:)) ?? .unknown))
        case .marker:
            self = .marker(at: try container.decode(AudioTime.self, forKey: .time))
        case .paused:
            self = .paused(at: try container.decode(AudioTime.self, forKey: .time))
        case .resumed:
            self = .resumed(at: try container.decode(AudioTime.self, forKey: .time))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .source(let text), .translation(let text):
            try container.encode(text.at, forKey: .time)
            try container.encode(text.text, forKey: .text)
            if text.kind == .segmentEnd { try container.encode(true, forKey: .end) }
        case .gap(let gap):
            try container.encode(gap.from, forKey: .from)
            try container.encode(gap.to, forKey: .to)
            try container.encode(gap.reason.rawValue, forKey: .why)
        case .marker(let time), .paused(let time), .resumed(let time):
            try container.encode(time, forKey: .time)
        }
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
///
/// 做法：檔案以 `O_APPEND` 開啟，每筆紀錄先在記憶體裡排成「一行＋換行」，再用一次 `write(2)` 寫出。
/// 鎖只包住那一次 `write(2)`（以及關檔），所以多條執行緒同時寫入時每一行都完整、不會交錯。
public final class JournalWriter: @unchecked Sendable {
    // @unchecked Sendable：唯一可變的狀態是檔案描述子，只在 `descriptor` 這個 Mutex 裡讀寫；
    // `path` 建立後不再改變。
    private let descriptor: Mutex<Int32>
    private let path: String

    /// 開啟日誌檔。檔案不存在就建立；已存在就接在後面寫。
    ///
    /// 既有檔案的最後一行如果不完整（上次寫到一半被中斷），會先補上換行：
    /// 那半行之後讀取時算成一行看不懂的內容，新的紀錄則從新的一行開始，不會跟著損壞。
    public init(url: URL) throws {
        path = url.path
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileIO.posixError(errno, path: path) }
        do {
            try Self.terminateTruncatedLine(fd, path: path)
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = Mutex(fd)
    }

    deinit { close() }

    public func append(_ entry: JournalEntry) throws {
        let line = try JournalLine.encode(entry)
        try descriptor.withLock { fd in
            guard fd >= 0 else { throw JournalWriterError.closed(path: path) }
            try line.withUnsafeBytes { try FileIO.writeAll($0, to: fd, path: path) }
        }
    }

    /// 關檔。重複呼叫不算錯；關檔之後再 `append` 會丟出錯誤。
    public func close() {
        descriptor.withLock { fd in
            guard fd >= 0 else { return }
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    private static func terminateTruncatedLine(_ fd: Int32, path: String) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw FileIO.posixError(errno, path: path) }
        guard status.st_size > 0 else { return }
        var last: UInt8 = 0
        guard pread(fd, &last, 1, status.st_size - 1) == 1 else { throw FileIO.posixError(errno, path: path) }
        if last != JournalLine.newline {
            try [JournalLine.newline].withUnsafeBytes { try FileIO.writeAll($0, to: fd, path: path) }
        }
    }
}

enum JournalWriterError: Error, CustomStringConvertible {
    case closed(path: String)

    var description: String {
        switch self {
        case .closed(let path): "日誌已經關閉，不能再寫入：\(path)"
        }
    }
}

public enum JournalReader {
    /// 讀取日誌。讀不懂的行會跳過並計數，不會讓整個讀取失敗；檔案不存在則丟出錯誤。
    ///
    /// 寫入端每筆都是「一行＋換行」一次寫出，所以沒有以換行結尾的最後一行一律視為寫到一半被中斷：
    /// 就算剩下的內容剛好是合法的 JSON 也不採用，只把 `hasTruncatedTail` 設為 true。
    public static func read(_ url: URL) throws -> JournalContents {
        let data = try Data(contentsOf: url)
        var contents = JournalContents()
        let decoder = JSONDecoder()
        let lines = data.split(separator: JournalLine.newline, omittingEmptySubsequences: false)
        // 檔案以換行結尾時，最後一段是空的；否則最後一段就是不完整的那一行
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 {
                contents.hasTruncatedTail = !line.isEmpty
                break
            }
            if let entry = try? decoder.decode(JournalEntry.self, from: line) {
                contents.entries.append(entry)
            } else {
                contents.skippedLineCount += 1
            }
        }
        return contents
    }
}

/// 把一筆紀錄排成日誌裡的一行（含結尾的換行）。
///
/// 不用 `JSONEncoder`：它的欄位順序每次執行都不一樣。這裡固定照文件記載的順序（`k` 在最前面），
/// 文字以 UTF-8 原文輸出，只跳脫 JSON 規定必須跳脫的字元（引號、反斜線、控制字元），斜線不跳脫。
enum JournalLine {
    static let newline = UInt8(ascii: "\n")

    static func encode(_ entry: JournalEntry) throws -> [UInt8] {
        var line: [UInt8] = []
        line.reserveCapacity(96)
        append(#"{"k":""#, to: &line)
        append(entry.kind.rawValue, to: &line)
        line.append(UInt8(ascii: "\""))
        switch entry {
        case .source(let text), .translation(let text):
            append(#","t":"#, to: &line)
            try appendNumber(text.at.seconds, to: &line)
            append(#","x":"#, to: &line)
            appendString(text.text, to: &line)
            if text.kind == .segmentEnd { append(#","end":true"#, to: &line) }
        case .gap(let gap):
            append(#","from":"#, to: &line)
            try appendNumber(gap.from.seconds, to: &line)
            append(#","to":"#, to: &line)
            try appendNumber(gap.to.seconds, to: &line)
            append(#","why":"#, to: &line)
            appendString(gap.reason.rawValue, to: &line)
        case .marker(let time), .paused(let time), .resumed(let time):
            append(#","t":"#, to: &line)
            try appendNumber(time.seconds, to: &line)
        }
        line.append(UInt8(ascii: "}"))
        line.append(newline)
        return line
    }

    private static func append(_ literal: String, to line: inout [UInt8]) {
        line.append(contentsOf: literal.utf8)
    }

    /// 整數值寫成整數（`30` 而不是 `30.0`），其他寫成能精確讀回的最短十進位表示。
    private static func appendNumber(_ value: Double, to line: inout [UInt8]) throws {
        guard value.isFinite else {
            throw EncodingError.invalidValue(
                value, EncodingError.Context(codingPath: [], debugDescription: "日誌裡的時間必須是有限的數字"))
        }
        if value.rounded() == value, abs(value) < 1e15 {
            append(String(Int64(value)), to: &line)
        } else {
            append(value.description, to: &line)
        }
    }

    private static func appendString(_ string: String, to line: inout [UInt8]) {
        line.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): append(#"\""#, to: &line)
            case UInt8(ascii: "\\"): append(#"\\"#, to: &line)
            case UInt8(ascii: "\n"): append(#"\n"#, to: &line)
            case UInt8(ascii: "\r"): append(#"\r"#, to: &line)
            case UInt8(ascii: "\t"): append(#"\t"#, to: &line)
            case 0x08: append(#"\b"#, to: &line)
            case 0x0C: append(#"\f"#, to: &line)
            case 0x00..<0x20:
                // 其餘的控制字元 JSON 規定一定要跳脫
                let hex = Array("0123456789abcdef".utf8)
                append(#"\u00"#, to: &line)
                line.append(hex[Int(byte >> 4)])
                line.append(hex[Int(byte & 0x0F)])
            default:
                line.append(byte)
            }
        }
        line.append(UInt8(ascii: "\""))
    }
}
