/// 開始／停止的按鈕位置。
///
/// 有兩個位置：主要位置（「開始錄音」所在的位置），以及它左邊的停止位置。
/// 錄音中與暫停時，主要位置變成「暫停」／「繼續」，「停止」出現在左邊的停止位置。
/// 停止鈕永遠不會佔用主要位置：剛按下開始時手快多點一下，最多是暫停，不會把錄音停掉。
///
/// 尚未實作：介面先行，見 `TransportSlotsTests`。
public struct TransportSlots: Sendable, Equatable {
    /// 主要位置顯示的東西。
    public enum Main: Sendable, Hashable, CaseIterable {
        /// 「開始錄音」。開始中、「準備中」還沒出現時也是它：畫成按下去的樣子，不接受點擊。
        case start
        /// 「準備中」：開始中，而且延遲顯示的提示已經出現。
        case preparing
        /// 「暫停」。
        case pause
        /// 「繼續」。
        case resume
        /// 「收尾中」。
        case finishing
    }

    /// 主要位置。
    public let main: Main
    /// 左邊的停止位置有沒有「停止」。
    public let showsStop: Bool

    /// - Parameters:
    ///   - phase: 錄音的階段。
    ///   - preparingVisible: 延遲顯示的「準備中」是不是已經出現（`DelayedIndicator.isVisible(at:)`）。只在開始中有作用。
    public init(phase: RecorderPhase, preparingVisible: Bool) {
        main = .start
        showsStop = false
    }
}
