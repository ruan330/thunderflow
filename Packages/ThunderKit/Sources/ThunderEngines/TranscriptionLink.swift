import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public struct TranscriptionLink: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var settings = TranscriptionSettings()
        /// 沒連上的時候最多保留多久的音訊。
        public var backlogDuration: TimeInterval = 10
        public var backoffBase: TimeInterval = 1
        public var backoffLimit: TimeInterval = 30
        /// 退避時間的隨機抖動：實際等待時間是「基準 ×（1 ± jitter）」。0 表示不抖動。
        public var jitter: Double = 0.2
        /// 建立連線後這麼久還沒收到 `session.updated`，就當成連線失敗。
        public var connectTimeout: TimeInterval = 10
        /// 連線滿這麼久之後，在下一次停頓時換線。伺服器的上限是 60 分鐘。
        public var rotationAge: TimeInterval = 45 * 60
        /// 距離上次 commit 超過這麼久，在下一次停頓時 commit 一次。
        public var commitInterval: TimeInterval = 5 * 60
        /// 音訊中斷這麼久（使用者暫停），就把手上的語音 commit。
        public var audioGapBeforeCommit: TimeInterval = 1
        /// 這麼久沒有音訊就關閉連線。
        public var idleClose: TimeInterval = 5 * 60
        /// commit 之後最多等完成事件多久。
        public var completionTimeout: TimeInterval = 3
        /// 每送出這麼多秒的音訊，回報一次累計的計費秒數。
        public var billingReportInterval: TimeInterval = 10

        public init() {}
    }

    /// 連線為什麼斷了。
    public enum CloseReason: Sendable, Equatable {
        /// API Key 無效（HTTP 401，或伺服器以代碼 3000 關閉）。
        case unauthorized
        /// 請求過多（HTTP 429）。
        case rateLimited
        /// 其他：網路錯誤、伺服器直接切斷、逾時。
        case lost
    }

    public enum Effect: Sendable, Equatable {
        /// 建立一條新連線，編號是 `connection`（只增不減）。之後這條連線的事件都帶這個編號。
        case open(connection: Int)
        case send(connection: Int, message: String)
        case close(connection: Int)
        /// 轉錄出來的增量文字。
        case text(String)
        case status(EngineStatus)
        /// 沒有送到伺服器的音訊。
        case gap(AudioGap)
        /// 到目前為止送給伺服器的音訊長度（秒），也就是計費的依據。
        case billed(seconds: Double)
        /// 收尾完成：不會再有文字，也不需要再呼叫任何方法。
        case finished
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration(), seed: UInt64 = 0) {
        self.configuration = configuration
    }

    public var nextDeadline: TimeInterval? { nil }
    public var isOver: Bool { false }
    public mutating func start(at now: TimeInterval) -> [Effect] { [] }
    public mutating func audio(_ chunk: AudioChunk, at now: TimeInterval) -> [Effect] { [] }
    public mutating func audioEnded(at now: TimeInterval) -> [Effect] { [] }
    public mutating func pauseDetected(at now: TimeInterval) -> [Effect] { [] }
    public mutating func received(_ event: TranscriptionEvent, connection source: Int, at now: TimeInterval) -> [Effect] { [] }
    public mutating func closed(connection source: Int, reason: CloseReason, at now: TimeInterval) -> [Effect] { [] }
    public mutating func advance(to now: TimeInterval) -> [Effect] { [] }
}
