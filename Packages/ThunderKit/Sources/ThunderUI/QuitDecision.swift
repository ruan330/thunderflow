/// 結束 ThunderFlow 時（⌘Q、選單的「結束 ThunderFlow」，或系統要登出、重新開機、關機）錄音怎麼辦。
public enum QuitDecision: Sendable, Equatable {
    /// 直接結束。
    case now
    /// 先問：「錄音中。要停止錄音並結束 ThunderFlow 嗎？」［停止並結束］［取消］。
    case ask
    /// 不問，先把錄音停好再結束。
    case stopFirst

    /// - Parameters:
    ///   - phase: 實際的階段。
    ///   - systemPoweringOff: 系統要登出、重新開機或關機。
    public init(phase: RecorderPhase, systemPoweringOff: Bool) {
        // 暫時照目前的做法（一律直接結束），測試會指出問題；實作時改掉
        self = .now
    }
}
