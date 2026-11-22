/// 錄音的指令（「錄音」選單與即時翻譯頁的按鈕，DESIGN.md 4.8 節）在各個階段能不能用。
///
/// 看實際的階段，不看畫面上延遲顯示的階段（`RecorderPhase.shown`）：按下停止之後的 0.3 秒內，按鈕還維持錄音中的樣子，
/// 但暫停、停止、標記都已經不能再做。開始中與收尾中什麼都不能做。
public struct RecordingCommands: Sendable, Equatable {
    /// 開始錄音（⌘N）：只有尚未開始時。開始中再按不會開始第二場。
    public let canStart: Bool
    /// 暫停或繼續：錄音中與暫停時。收尾中不行：會把狀態改回錄音中，停止鈕再出現，同一場就可能被停止兩次。
    public let canTogglePause: Bool
    /// 暫停或繼續的名稱：暫停時是「繼續」，其他時候是「暫停」。
    public let pauseTitle: String
    /// 停止（⌘.）：錄音中與暫停時。
    public let canStop: Bool
    /// 標記重點（⌘B）：錄音中與暫停時。
    public let canMark: Bool

    /// - Parameter phase: 實際的階段（不是畫面上延遲顯示的階段）。
    public init(phase: RecorderPhase) {
        let active = phase == .recording || phase == .paused
        canStart = phase == .idle
        canTogglePause = active
        pauseTitle = phase == .paused ? "繼續" : "暫停"
        canStop = active
        canMark = active
    }
}
