/// 防連點：一組按鈕的狀態改變之後，0.5 秒內的點擊不算數。
///
/// 例如按下「開始錄音」之後，同一個位置馬上變成「暫停」：手快多點了一下，也不會一開始就暫停。
/// 時間由呼叫的人傳入（DESIGN.md 9.3 節：時間是輸入），所以測試不用真的等。
public struct PressGuard: Sendable, Equatable {
    /// 狀態改變之後，多久之內的點擊不算數。
    public let window: Duration
    /// 最近一次狀態改變的時間。
    private var changedAt: ContinuousClock.Instant?

    public init(window: Duration = .milliseconds(500)) {
        self.window = window
    }

    /// 這組按鈕的狀態改變了（例如錄音中變成暫停）：從 `now` 起重新計算。
    public mutating func stateChanged(at now: ContinuousClock.Instant) {
        changedAt = now
    }

    /// 在 `now` 的點擊算不算數。還沒有狀態改變過時一律算數；改變之後未滿 `window` 的不算，剛好滿 `window` 就算。
    public func accepts(at now: ContinuousClock.Instant) -> Bool {
        guard let changedAt else { return true }
        return now >= changedAt + window
    }
}
