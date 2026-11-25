import Foundation

/// 給 AI agent 讀的即時逐字稿：`<場次資料夾>/live-transcript.txt`（DESIGN.md 5.9 節，D34）。
extension SessionDirectory {
    /// 錄音中的即時逐字稿。基本逐字稿做好時刪除，之後改看 `transcript.md`。
    public var liveTranscriptURL: URL { url.appendingPathComponent("live-transcript.txt") }
    /// 工作坊教材：每次下載一個子資料夾。
    public var workshopURL: URL { url.appendingPathComponent("workshop", isDirectory: true) }
}

/// 即時逐字稿的一行。
public enum LiveTranscriptEntry: Sendable, Equatable {
    /// 一段英文確定了（`segment` 是段號；同一段之後再確定一次，例如補上晚到的標點，不再寫）。
    case speech(String, segment: Int?)
    /// 使用者標記的重點。
    case marker
    case paused
    case resumed
    /// 沒有字幕的一段：引擎回報的缺口，或錄音中斷（`AudioGap.isInterruption`）。
    case gap(AudioGap)
}

/// 寫即時逐字稿：建立時寫入兩行說明，之後每一筆寫一行，只往後加。可以從任何執行緒呼叫。
///
/// 寫入失敗不丟出錯誤：這個檔只是給 agent 讀的副本，不能影響錄音。資料來源永遠是日誌。
public final class LiveTranscriptWriter: Sendable {
    /// - Parameters:
    ///   - title: 場次的標題（空的就不寫）。
    ///   - startedAt: 開始的時間，寫在說明裡。
    ///   - timeZone: 時刻用的時區。
    ///   - clock: 每一行前面的時刻（寫入當下）。
    public init(
        url: URL, title: String, startedAt: Date, timeZone: TimeZone = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {}

    public func append(_ entry: LiveTranscriptEntry) {}

    /// 關檔。重複呼叫不算錯；關檔之後的 `append` 什麼都不做。
    public func close() {}
}
