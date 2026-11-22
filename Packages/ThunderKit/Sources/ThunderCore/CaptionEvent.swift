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
    /// 段號：一段英文和它的中文（定稿與暫定譯文）用同一個號碼，從 0 開始、只增不減。
    /// 不分段的引擎，以及加入段號之前寫下的日誌，這個值是 nil。
    public var segment: Int?
    /// 句子的編號（整句模式，DESIGN.md 5.6.2 節）：從 0 開始、只增不減，一句可能包含好幾段。
    /// 英文（增量與確定）帶的是這一段屬於第幾句，給畫面把同一句的段合成一個段落；整句定稿帶的是它翻的那一句。
    /// 不是整句模式時是 nil。
    public var sentence: Int?
    /// 只用在中文定稿：不是 nil 時，這是一整句的定稿，涵蓋第 `sentenceStart` 段到第 `segment` 段（這一句的最後一段），
    /// 取代這幾段各自的定稿。nil 表示只是一段的定稿。
    public var sentenceStart: Int?

    public init(text: String, kind: TextKind, at: AudioTime, segment: Int? = nil, sentence: Int? = nil, sentenceStart: Int? = nil) {
        self.text = text
        self.kind = kind
        self.at = at
        self.segment = segment
        self.sentence = sentence
        self.sentenceStart = sentenceStart
    }
}

public enum EngineStatus: Sendable, Equatable {
    case connecting
    case live
    case reconnecting
    /// 一段時間沒有音訊（例如使用者暫停），引擎已主動收尾並關閉連線。
    case idle
    case failed(reason: String)
    /// 轉錄照常（英文字幕與錄音持續），但翻譯連續失敗：文字模型一直回錯誤（例如模型名稱不對、Key 沒有權限、額度用完）。
    /// `reason` 是最近一次的錯誤。翻譯恢復時回到 `live`。
    case translationFailing(reason: String)
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
    ///
    /// 原因不同的缺口一律不合併；同一個原因的缺口之間就算夾著別的原因，相連或重疊的仍然會合併，
    /// 所以合併後同一個原因的缺口彼此不重疊，長度可以直接加總。
    /// 結果依開始時間排序（開始時間相同時依結束時間、原因），與輸入順序無關。
    public static func coalesced(_ gaps: [AudioGap]) -> [AudioGap] {
        let ordered = gaps.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            if lhs.to != rhs.to { return lhs.to < rhs.to }
            return lhs.reason.rawValue < rhs.reason.rawValue
        }
        var merged: [AudioGap] = []
        // 每個原因目前最後一筆（結束時間最晚的一筆）在 merged 裡的位置
        var lastIndexByReason: [GapReason: Int] = [:]
        for gap in ordered {
            if let index = lastIndexByReason[gap.reason], gap.from.seconds <= merged[index].to.seconds + seamTolerance {
                merged[index].to = max(merged[index].to, gap.to)
            } else {
                lastIndexByReason[gap.reason] = merged.count
                merged.append(gap)
            }
        }
        return merged
    }

    /// 兩個缺口之間的縫隙在這個長度以內（秒）就視為相連。
    private static let seamTolerance: TimeInterval = 0.001
}

/// 即時字幕引擎送出的事件。
public enum CaptionEvent: Sendable, Equatable {
    /// 來源語言的文字（英文）。
    /// - `delta`：這一段新增的文字，接在同一段已經出現的文字後面。
    /// - `segmentEnd`：這一段確定了，`text` 是整段的完整文字。同一個段號之後如果又出現一次（補上晚到的標點），以最後一次為準。
    case source(CaptionText)
    /// 翻譯後的文字（中文定稿）。一段送一次（`segmentEnd`，`text` 是整段的譯文），取代這一段的暫定譯文。
    case translation(CaptionText)
    /// 暫定譯文：這一段還沒說完時先翻出來給畫面顯示的中文。`text` 是到目前為止整段的暫定譯文，
    /// 取代同一段上一次的暫定譯文。只給畫面用，不寫進日誌。
    case provisional(CaptionText)
    case status(EngineStatus)
    case gap(AudioGap)
    /// 到目前為止累計計費的音訊秒數。
    case usage(audioSeconds: Double)
}
