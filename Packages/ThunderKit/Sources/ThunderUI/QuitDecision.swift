/// 結束 ThunderFlow 時（⌘Q、選單的「結束 ThunderFlow」，或系統要登出、重新開機、關機）錄音怎麼辦。
///
/// 錄音只由使用者結束（D26）：使用者自己要結束 App 時先問；系統要登出或關機時不問（使用者已經要求登出或關機，
/// 問了也只會擋住），先把這一場好好停下來再結束，最後幾段的翻譯與 `session.json` 都寫完，下次開啟時不會被當成
/// 異常結束的場次。結束處理（合併錄音、搬進 Library、摘要）下次開啟 App 時接著做。
public enum QuitDecision: Sendable, Equatable {
    /// 直接結束：沒有在錄音。
    case now
    /// 先問：「錄音中。要停止錄音並結束 ThunderFlow 嗎？」［停止並結束］［取消］。
    case ask
    /// 不問，先把錄音停好再結束：開始中先等它開始，錄音中與暫停時停止，收尾中等它停完。
    case stopFirst

    /// - Parameters:
    ///   - phase: 實際的階段（不是畫面上延遲顯示的階段）。
    ///   - systemPoweringOff: 系統要登出、重新開機或關機（`NSWorkspace.willPowerOffNotification`）。
    public init(phase: RecorderPhase, systemPoweringOff: Bool) {
        switch phase {
        case .idle: self = .now
        // 已經按了停止：等它停完，不用再問
        case .stopping: self = .stopFirst
        case .starting, .recording, .paused: self = systemPoweringOff ? .stopFirst : .ask
        }
    }
}
