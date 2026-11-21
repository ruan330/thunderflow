import Foundation

/// 一個場次資料夾的獨占鎖：同一時間只有一方可以處理這個場次（正在錄音的場次，或正在做結束處理的那一方）。
///
/// 尚未實作：介面先行，見 `SessionLockTests`。
public final class SessionLock: Sendable {
    private init() {}

    /// 試著鎖住 `directory`，不等待。別人（包括同一個程式裡的其他地方）正持有時回傳 nil。
    /// 資料夾打不開（例如不存在）時丟出錯誤。
    public static func acquire(_ directory: SessionDirectory) throws -> SessionLock? {
        SessionLock()
    }

    /// 有沒有人（包括同一個程式裡的其他地方）正持有 `directory` 的鎖。資料夾不存在時回答 false。
    public static func isHeld(_ directory: SessionDirectory) -> Bool {
        false
    }

    /// 釋放。可以重複呼叫；物件被釋放時也會自動釋放。
    public func release() {}
}
