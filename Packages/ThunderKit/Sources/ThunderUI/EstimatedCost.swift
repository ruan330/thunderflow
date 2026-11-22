import Foundation

/// 預估的 API 費用（DESIGN.md 4.3 節的狀態列、4.6 節的詳細頁）。照公告價格與實測的用量換算，只是估計，不是帳單。
public struct EstimatedCost: Sendable, Equatable {
    /// 轉錄：每分鐘 US$0.017。
    public static let transcriptionPerMinute = 0.017
    /// 翻譯：每小時約 US$0.08（各段的定稿約 0.03、整句定稿約 0.05，DESIGN.md 9.7 節）。
    public static let translationPerHour = 0.08
    /// 開了暫定譯文時的翻譯：整句的暫定譯文再加約 0.19，每小時約 US$0.27。
    public static let translationPerHourWithProvisional = 0.27

    /// 美元。
    public let dollars: Double

    /// - Parameters:
    ///   - audioSeconds: 錄下的長度（秒）。
    ///   - billedSeconds: 引擎回報的計費秒數；nil 是還沒有回報。
    ///   - provisional: 這一場有沒有開暫定譯文。
    public init(audioSeconds: Double, billedSeconds: Double?, provisional: Bool) {
        // 暫時照目前 App 的做法（只看錄下的長度），測試會指出問題；實作時改掉
        dollars =
            audioSeconds / 60 * Self.transcriptionPerMinute
            + audioSeconds / 3_600 * (provisional ? Self.translationPerHourWithProvisional : Self.translationPerHour)
    }

    /// 「約 $0.80」。
    public var text: String { String(format: "約 $%.2f", dollars) }
}
