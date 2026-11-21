/// 延遲顯示的等待提示（例如「準備中」）：等待在 0.3 秒內結束就什麼都不顯示，等滿 0.3 秒才出現。
///
/// 很快就做完的操作，畫面不會閃一下提示又消失。畫面在 `revealsAt` 重畫一次，提示就會在對的時間出現。
///
/// 尚未實作：介面先行，見 `DelayedIndicatorTests`。
public struct DelayedIndicator: Sendable, Equatable {
    /// 等待多久之後才顯示提示。
    public let delay: Duration

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    /// 開始等待。已經在等的時候不重新計時（畫面多呼叫一次，已經出現的提示也不會消失再出現）。
    public mutating func begin(at now: ContinuousClock.Instant) {}

    /// 等待結束：提示馬上消失，還沒出現的就不會再出現。
    public mutating func end() {}

    /// 在 `now` 時要不要顯示提示：正在等，而且已經等了至少 `delay`。
    public func isVisible(at now: ContinuousClock.Instant) -> Bool {
        false
    }

    /// 提示出現的時間（可能已經過了）；沒有在等的時候是 nil。畫面在這個時間重畫一次。
    public var revealsAt: ContinuousClock.Instant? {
        nil
    }
}
