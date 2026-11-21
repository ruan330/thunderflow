import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
/// 轉錄連線的設定（DESIGN.md 5.6.2 節的表）。模型與延遲都是設定值，不寫死。
public struct TranscriptionSettings: Sendable, Equatable {
    public var model: String = "gpt-live-transcribe"
    /// `minimal`、`low`、`medium`、`high`、`xhigh`。v1 用 `low`。
    public var delay: String = "low"
    public var languages: [String] = ["en"]
    /// 人名、產品名稱、術語。空白的與重複的會去掉。
    public var keywords: [String] = []
    /// 給轉錄模型的說明（例如場次的標題與講者）。超過 `TranscriptionCommand.promptLimit` 個字元的部分會被截掉。
    public var prompt: String = ""

    public init() {}
}

public enum TranscriptionEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    /// 增量文字：只往後加，不改寫。
    case delta(itemID: String, text: String)
    /// commit 之後，這一段的完整文字與計費秒數。
    case completed(itemID: String, transcript: String, billedSeconds: Double)
    case committed(itemID: String)
    case error(code: String, message: String)
    case other(type: String)

    public init?(message: String) {
        return nil
    }
}

public enum TranscriptionCommand {
    public static let promptLimit = 1_024
    public static func sessionUpdate(_ settings: TranscriptionSettings) -> String { "" }
    public static func append(_ chunk: AudioChunk) -> String { "" }
    public static let commit = "{\"type\":\"input_audio_buffer.commit\"}"
    public static func cleaned(_ keywords: [String]) -> [String] { [] }
}
