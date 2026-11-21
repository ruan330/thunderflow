import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public struct TranslationPlanner: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var model: String = "gpt-6-luna"
        /// 是否產生暫定譯文。
        public var provisional: Bool = true
        public var provisionalWords: Int = 3
        public var provisionalInterval: TimeInterval = 1
        public var provisionalTimeout: TimeInterval = 4
        public var hedgeAfter: TimeInterval = 3
        public var giveUpAfter: TimeInterval = 8
        /// 一段最多送出幾個請求（含重試與備援）。
        public var maximumAttempts: Int = 3
        /// 帶前幾段英文當上下文。
        public var contextSegments: Int = 2
        /// 場次資訊與關鍵詞：放進提示，讓專有名詞保留原文。
        public var title: String = ""
        public var event: String = ""
        public var speaker: String = ""
        public var keywords: [String] = []

        public init() {}
    }

    public enum Effect: Sendable, Equatable {
        /// 送出一個請求，編號是 `request`。之後這個請求的輸出、完成、失敗都帶這個編號回報。
        case start(request: Int, TextRequest)
        /// 取消一個還沒完成的請求。取消之後不需要再回報它的結果。
        case cancel(request: Int)
        /// 第 `segment` 段的中文定稿。
        case translation(segment: Int, text: String)
        /// 第 `segment` 段到目前為止的暫定譯文（整段取代上一次的）。
        case provisional(segment: Int, text: String)
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var hasPendingFinals: Bool { false }
    public var nextDeadline: TimeInterval? { nil }
    public mutating func segmentFinished(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] { [] }
    public mutating func segmentExtended(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] { [] }
    public mutating func pendingText(_ text: String, segment: Int, at now: TimeInterval) -> [Effect] { [] }
    public mutating func progress(request: Int, text: String, at now: TimeInterval) -> [Effect] { [] }
    public mutating func completed(request: Int, text: String, at now: TimeInterval) -> [Effect] { [] }
    public mutating func failed(request: Int, at now: TimeInterval) -> [Effect] { [] }
    public mutating func advance(to now: TimeInterval) -> [Effect] { [] }
}
