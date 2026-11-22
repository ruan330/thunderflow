import Foundation
import ThunderCore

/// 上次沒有正常結束的場次（App 當掉、被強制結束）開啟 App 時怎麼問使用者（D26、DESIGN.md 5.5 節）。純函式，有測試。
///
/// 不自動接著錄（使用者可能隔了很久才打開 App），也不再不問就收尾。好幾場時一次問：
/// 「結束並產生逐字稿」把它們都做完；「稍後再決定」留在工作目錄，下次開啟 App 再問。
public struct InterruptedSessionPrompt: Sendable, Equatable {
    public var message: String

    public static let finishLabel = "結束並產生逐字稿"
    public static let laterLabel = "稍後再決定"

    /// - Parameters:
    ///   - sessions: 上次沒有正常結束的場次（`SessionRecovery.findInterrupted`）。
    ///   - now: 現在，用來說「多久以前中斷」。
    /// - Returns: 沒有這種場次時是 nil。
    public init?(sessions: [InterruptedSession], now: Date) {
        return nil
    }
}
