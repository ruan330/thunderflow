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
    /// 錄音中斷：電腦睡眠。醒來之後接著錄同一場，睡眠的時間沒有錄到（DESIGN.md 5.4 節）。
    case sleep
    /// 錄音中斷：收音裝置不見了（拔掉 USB 麥克風、AirPods 斷線），改用別的裝置接著錄。
    case deviceLost
    /// 錄音中斷：錄系統音訊時預設的輸出裝置換了（例如接上或拔掉 AirPods），用新的輸出裝置接著錄。
    case outputChanged
    /// 錄音中斷：收音停了（一段時間沒有收到任何聲音資料），重新開始收音接著錄。
    case captureStalled
    /// 換了音訊來源：使用者在錄音中或暫停中選了別的來源，用新的來源接著錄同一場（D35）。
    case sourceChanged
    case unknown
}

/// 一段沒有被翻譯到的音訊。錄音本身不受影響，之後可以補翻。
///
/// 錄音中斷（原因是 `sleep`、`deviceLost`、`outputChanged`、`captureStalled`）也記成一筆缺口：
/// 在中斷的音訊時間，長度是 0（錄音直接接在中斷之前的聲音後面，不補靜音），`lostSeconds` 是沒有錄到的時間。
public struct AudioGap: Sendable, Equatable {
    public var from: AudioTime
    public var to: AudioTime
    public var reason: GapReason
    /// 錄音中斷時，中斷期間沒有錄到的時間（實際經過的秒數）。其他缺口是 0。
    public var lostSeconds: TimeInterval
    /// 換了音訊來源（`sourceChanged`）時，之後用的來源，例如「MacBook Pro 麥克風」。其他缺口是 nil。
    public var source: String?

    public init(from: AudioTime, to: AudioTime, reason: GapReason, lostSeconds: TimeInterval = 0, source: String? = nil) {
        self.from = from
        self.to = to
        self.reason = reason
        self.lostSeconds = lostSeconds
        self.source = source
    }

    /// 錄音中斷：在音訊時間 `time` 這裡，有 `lostSeconds` 秒（實際經過的時間）沒有錄到。
    /// 換了音訊來源時，`source` 是之後用的來源。
    public static func interruption(
        at time: AudioTime, lostSeconds: TimeInterval, reason: GapReason, source: String? = nil
    ) -> AudioGap {
        AudioGap(from: time, to: time, reason: reason, lostSeconds: lostSeconds, source: source)
    }

    /// 這是一筆錄音中斷（睡眠、裝置不見、換了輸出裝置、收音停了、換了音訊來源）。
    public var isInterruption: Bool {
        switch reason {
        case .sleep, .deviceLost, .outputChanged, .captureStalled, .sourceChanged: true
        case .network, .backpressure, .engineStopped, .unknown: false
        }
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
                merged[index].lostSeconds += gap.lostSeconds
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
