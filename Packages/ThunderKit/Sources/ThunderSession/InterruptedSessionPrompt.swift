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
        guard let latest = sessions.max(by: { $0.lastWrittenAt < $1.lastWrittenAt }) else { return nil }
        let ago = Self.ago(now.timeIntervalSince(latest.lastWrittenAt))
        let question = "已經錄下的聲音都還在。要「\(Self.finishLabel)」，還是「\(Self.laterLabel)」？"
        if sessions.count == 1 {
            let title = latest.meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let which = title.isEmpty ? "上次的錄音" : "上次的錄音「\(title)」"
            message = "\(which)在 \(ago)中斷了，已經錄下 \(Timecode.duration(latest.recordedDuration))。" + question
        } else {
            message = "有 \(sessions.count) 場錄音上次沒有正常結束，最近的一場在 \(ago)中斷。" + question
        }
    }

    /// 多久以前：不到 1 分鐘前、N 分鐘前、N 小時前、N 天前（捨去）。
    private static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "不到 1 分鐘前" }
        if minutes < 60 { return "\(minutes) 分鐘前" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小時前" }
        return "\(minutes / (24 * 60)) 天前"
    }
}
