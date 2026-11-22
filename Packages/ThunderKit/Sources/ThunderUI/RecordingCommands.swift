/// 錄音的指令（「錄音」選單與即時翻譯頁的按鈕，DESIGN.md 4.8 節）在各個階段能不能用。
public struct RecordingCommands: Sendable, Equatable {
    /// 開始錄音（⌘N）。
    public let canStart: Bool
    /// 暫停或繼續。
    public let canTogglePause: Bool
    /// 暫停或繼續的名稱。
    public let pauseTitle: String
    /// 停止（⌘.）。
    public let canStop: Bool
    /// 標記重點（⌘B）。
    public let canMark: Bool

    /// - Parameter phase: 實際的階段（不是畫面上延遲顯示的階段）。
    public init(phase: RecorderPhase) {
        // 暫時沒有任何限制（目前的 togglePause 不看階段），測試會指出問題；實作時改掉
        canStart = true
        canTogglePause = true
        pauseTitle = "暫停"
        canStop = true
        canMark = true
    }
}
