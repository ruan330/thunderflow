import Foundation

/// 把秒數排成給人看的時間。逐字稿、摘要、送給文字模型的內容與畫面共用，寫法才會一致。
public enum Timecode {
    /// 時間位置：`HH:MM:SS`，例如 95 秒是 `00:01:35`，100 小時是 `100:00:00`。
    /// 不足一秒的部分捨去；負數與不是數字的值當成 0。
    public static func clock(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds.rounded(.down))
        return "\(twoDigits(total / 3_600)):\(twoDigits(total / 60 % 60)):\(twoDigits(total % 60))"
    }

    /// 長度：不到一小時是 `M:SS`（`58:12`），一小時以上是 `H:MM:SS`（`1:42:05`）。
    /// 四捨五入到秒；負數與不是數字的值當成 0。
    public static func duration(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds.rounded())
        let hours = total / 3_600
        if hours > 0 {
            return "\(hours):\(twoDigits(total / 60 % 60)):\(twoDigits(total % 60))"
        }
        return "\(total / 60):\(twoDigits(total % 60))"
    }

    private static func wholeSeconds(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, 1e12))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
