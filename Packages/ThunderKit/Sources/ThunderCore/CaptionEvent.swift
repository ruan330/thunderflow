import Foundation

public enum TextKind: String, Sendable, Codable {
    /// 增量文字：接在同一句已經出現的文字後面。
    case delta
    /// 一句（或一段）到此結束。
    case segmentEnd
}

/// 引擎送出的一段文字。
public struct CaptionText: Sendable, Equatable {
    public var text: String
    public var kind: TextKind
    /// 收到這段文字時，已經送給引擎的音訊時間。
    public var at: AudioTime

    public init(text: String, kind: TextKind, at: AudioTime) {
        self.text = text
        self.kind = kind
        self.at = at
    }
}

public enum EngineStatus: Sendable, Equatable {
    case connecting
    case live
    case reconnecting
    /// 一段時間沒有音訊（例如使用者暫停），引擎已主動收尾並關閉連線。
    case idle
    case failed(reason: String)
}

/// 音訊為什麼沒有被翻譯到。
public enum GapReason: String, Sendable {
    /// 網路中斷期間來不及送出的音訊。
    case network
    /// 引擎消化太慢，等待區滿了而被丟掉的音訊。
    case backpressure
    /// 引擎已經停止（例如 API Key 失效）之後的音訊。
    case engineStopped
    case unknown
}

/// 一段沒有被翻譯到的音訊。錄音本身不受影響，之後可以補翻。
public struct AudioGap: Sendable, Equatable {
    public var from: AudioTime
    public var to: AudioTime
    public var reason: GapReason

    public init(from: AudioTime, to: AudioTime, reason: GapReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }

    public var duration: TimeInterval { to - from }

    /// 依開始時間排序，並把相連或重疊（誤差 1 毫秒以內）、原因相同的缺口合併成一筆。
    public static func coalesced(_ gaps: [AudioGap]) -> [AudioGap] {
        gaps // 尚未實作
    }
}

/// 即時字幕引擎送出的事件。
public enum CaptionEvent: Sendable, Equatable {
    /// 來源語言的文字（英文）。
    case source(CaptionText)
    /// 翻譯後的文字（中文）。
    case translation(CaptionText)
    case status(EngineStatus)
    case gap(AudioGap)
    /// 到目前為止累計計費的音訊秒數。
    case usage(audioSeconds: Double)
}
