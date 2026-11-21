import Foundation
import ThunderCore

/// 停頓偵測：從送給引擎的音訊判斷講者什麼時候開始說話、什麼時候停頓。
///
/// 只用來決定切段的時機（`Segmenter`），不影響辨識：偵測不準時只是切段早一點或晚一點。
///
/// 做法（DESIGN.md 5.6.2 節；實測見 M0b 報告 6.1 節）：
/// - 每 `frameDuration`（20 ms）算一次音量（RMS，16-bit 振幅單位）。
/// - **門檻隨底噪調整**：取最近 `window` 秒每一格的音量，第 10 百分位當底噪、第 90 百分位當語音
///   （語音至少算成底噪的 1.5 倍），門檻放在兩者之間（對數刻度）靠近底噪 `mix` 的位置，而且不低於 `minimumThreshold`。
///   現場收音的底噪很高，固定的門檻會完全偵測不到停頓。
/// - 音量高於門檻的格子是語音。連續 `minimumSpeech` 的語音算「開始說話」；
///   說話之後連續 `silenceDuration` 都不是語音，算一次「停頓」。
///
/// 只看過去的音訊，結果只取決於送進來的樣本，和包的切法、送的速度無關。
public struct PauseDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// 每一格的長度。
        public var frameDuration: TimeInterval = 0.02
        /// 說話之後連續靜音這麼久，算一次停頓。
        public var silenceDuration: TimeInterval = 0.3
        /// 連續這麼久的語音才算開始說話（避免把單獨一格的雜音當成語音）。
        public var minimumSpeech: TimeInterval = 0.04
        /// 估計底噪與語音音量用的時間窗。
        public var window: TimeInterval = 20
        /// 門檻在底噪與語音之間的位置（對數刻度）：0 是底噪，1 是語音。
        public var mix: Double = 0.25
        /// 門檻的下限（RMS，16-bit 振幅單位）。
        public var minimumThreshold: Double = 60

        public init() {}
    }

    public enum Event: Sendable, Equatable {
        /// 講者開始說話。`at` 是這段語音開始的音訊時間。
        case speechStarted(at: AudioTime)
        /// 講者停頓了。`speechEnd` 是最後一格語音結束的音訊時間；`at` 是偵測到的時間（靜音滿 `silenceDuration` 的那一刻）。
        case paused(speechEnd: AudioTime, at: AudioTime)
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 目前的門檻（RMS，16-bit 振幅單位）。還沒有收到任何音訊時是 `minimumThreshold`。
    public var threshold: Double {
        // 尚未實作（M2）
        0
    }

    /// 現在是不是在說話中：已經回報開始說話，還沒有回報停頓。
    public var isSpeaking: Bool {
        // 尚未實作（M2）
        false
    }

    /// 送入一包音訊（16-bit PCM、單聲道），回傳這一包裡發生的事件，依時間順序。
    ///
    /// 事件的時間是音訊時間：以包的 `startTime` 為準。不滿一格的樣本會留到下一包一起算。
    public mutating func process(_ chunk: AudioChunk) -> [Event] {
        // 尚未實作（M2）
        []
    }
}
