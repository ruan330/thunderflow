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
