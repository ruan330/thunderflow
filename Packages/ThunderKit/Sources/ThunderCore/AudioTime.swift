import Foundation

/// 音訊時間：從場次開始算起、扣掉暫停的錄音時間（秒）。
///
/// 字幕、缺口、標記的時間戳都用它，所以不受系統時鐘變更影響，
/// 也能直接對應到錄音檔裡的位置。
public struct AudioTime: Hashable, Comparable, Sendable, Codable {
    public var seconds: Double

    public init(seconds: Double) { self.seconds = seconds }

    public static let zero = AudioTime(seconds: 0)

    public static func < (lhs: AudioTime, rhs: AudioTime) -> Bool { lhs.seconds < rhs.seconds }
    public static func + (lhs: AudioTime, rhs: TimeInterval) -> AudioTime { AudioTime(seconds: lhs.seconds + rhs) }
    public static func - (lhs: AudioTime, rhs: AudioTime) -> TimeInterval { lhs.seconds - rhs.seconds }

    // 存檔時就是一個數字（秒）。
    public init(from decoder: any Decoder) throws {
        seconds = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}
