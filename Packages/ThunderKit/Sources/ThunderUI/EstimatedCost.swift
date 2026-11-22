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
    ///   - audioSeconds: 錄下的長度（秒）。引擎還沒回報計費秒數時（開始的前 10 秒）用它估計。
    ///   - billedSeconds: 引擎回報的計費秒數：送去轉錄的音訊（`LiveCaptionModel.billedSeconds`、
    ///     `SessionMeta.billedAudioSeconds`）。nil 是還沒有回報。轉錄照它算；翻譯也照它算：
    ///     沒有送去轉錄的聲音（例如翻譯斷線的那段）不會有譯文。
    ///   - provisional: 這一場有沒有開暫定譯文。要用開始時的設定：引擎的做法在開始時就固定了，
    ///     錄音中切換只改變顯示。
    public init(audioSeconds: Double, billedSeconds: Double?, provisional: Bool) {
        let seconds = billedSeconds ?? audioSeconds
        let translationPerHour = provisional ? Self.translationPerHourWithProvisional : Self.translationPerHour
        dollars = seconds / 60 * Self.transcriptionPerMinute + seconds / 3_600 * translationPerHour
    }

    /// 「約 $0.80」。
    public var text: String { String(format: "約 $%.2f", dollars) }
}
