/// 錄音的階段。即時翻譯頁的狀態標籤（`Indicator.recorder(_:)`）與開始／停止的按鈕（`TransportSlots`）都照它顯示。
///
/// App 把自己的狀態對應到這裡，畫面的判斷才能用 `swift test` 測到。
public enum RecorderPhase: Sendable, Hashable, CaseIterable {
    /// 還沒開始錄音。
    case idle
    /// 按下開始之後、真的開始收音之前。
    case starting
    case recording
    case paused
    /// 按下停止之後、這一場交出去處理之前。
    case stopping
}

extension RecorderPhase {
    /// 畫面上表示的階段（DESIGN.md 4.10.4、4.10.5）：開始中與收尾中這兩段等待未滿 0.3 秒時，畫面維持等待之前的樣子；
    /// 0.3 秒內就等完了，就直接換成結果，不會閃一下「準備中」「收尾中」。按鈕、狀態列與字幕區都照它顯示，所以會同時換。
    ///
    /// - Parameters:
    ///   - before: 這段等待開始之前的階段（尚未開始、錄音中或已暫停）。
    ///   - waitVisible: 延遲顯示的提示是不是已經出現（`DelayedIndicator.isVisible(at:)`）。
    public func shown(before: RecorderPhase, waitVisible: Bool) -> RecorderPhase {
        switch self {
        case .starting, .stopping: waitVisible ? self : before
        case .idle, .recording, .paused: self
        }
    }
}
