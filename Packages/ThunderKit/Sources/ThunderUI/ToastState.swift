/// 一則提示：結果在畫面上看不到的操作（標記重點、複製全文、儲存 Key）做完之後的短訊息。
public struct Toast: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// 標記重點。
        case marked
        /// 複製全文。
        case copied
        /// 儲存 Key。
        case saved
        /// 其他訊息。
        case info
    }

    /// 遞增的編號：每一則都比前一則大。同樣的訊息再出現一次也是新的一則，畫面可以重新播放出現的動畫。
    public let id: Int
    public let kind: Kind
    public let text: String
}

/// 目前的提示：一則顯示 1.5 秒；新的一則馬上取代目前的，不排隊。
///
/// 時間由呼叫的人傳入，畫面在 `expiresAt` 重畫一次，提示就會在對的時間消失。
///
/// 尚未實作：介面先行，見 `ToastStateTests`。
public struct ToastState: Sendable, Equatable {
    /// 一則提示顯示多久。
    public let duration: Duration

    public init(duration: Duration = .milliseconds(1500)) {
        self.duration = duration
    }

    /// 顯示一則新的提示，取代目前的（不論舊的還剩多久）。
    public mutating func post(_ kind: Toast.Kind, _ text: String, at now: ContinuousClock.Instant) {}

    /// 在 `now` 時要顯示的提示：最新的一則出現後未滿 `duration` 就是它，滿了就沒有。
    public func visible(at now: ContinuousClock.Instant) -> Toast? {
        nil
    }

    /// 最新的一則提示消失的時間（可能已經過了）；還沒有任何提示時是 nil。
    public var expiresAt: ContinuousClock.Instant? {
        nil
    }
}
