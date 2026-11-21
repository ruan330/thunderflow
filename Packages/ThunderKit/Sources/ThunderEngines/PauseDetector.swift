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

    // 還沒湊滿一格的樣本，以及目前這段連續音訊的起點與已經處理的格數。
    // 每一格的時間用「起點＋格數 × 每格長度」算，不用累加，所以和包的切法無關。
    private var pending: [Int16] = []
    private var sampleRate = 0
    private var origin = AudioTime.zero
    private var framesSinceOrigin = 0
    private var expectedNextStart: AudioTime?

    // 最近 `window` 秒每一格的音量：`recent` 依時間排（環狀），`ordered` 依大小排。
    private var recent: [Double] = []
    private var oldest = 0
    private var ordered: [Double] = []
    private var currentThreshold: Double

    private var speaking = false
    private var speechRun = 0
    private var speechRunStart = AudioTime.zero
    private var silenceRun = 0
    private var lastSpeechEnd = AudioTime.zero

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        currentThreshold = configuration.minimumThreshold
    }

    /// 目前的門檻（RMS，16-bit 振幅單位）。還沒有收到任何音訊時是 `minimumThreshold`。
    public var threshold: Double { currentThreshold }

    /// 現在是不是在說話中：已經回報開始說話，還沒有回報停頓。
    public var isSpeaking: Bool { speaking }

    /// 送入一包音訊（16-bit PCM、單聲道），回傳這一包裡發生的事件，依時間順序。
    ///
    /// 事件的時間是音訊時間：以包的 `startTime` 為準。不滿一格的樣本會留到下一包一起算。
    public mutating func process(_ chunk: AudioChunk) -> [Event] {
        guard chunk.sampleRate > 0, chunk.frameCount > 0 else { return [] }
        let frameDuration = configuration.frameDuration
        let frameLength = max(1, Int((frameDuration * Double(chunk.sampleRate)).rounded()))

        // 取樣率改變，或音訊時間不連續（中間有一段沒有送到）：從這一包重新起算。
        // 缺的那一段不算靜音也不算語音；說話中的狀態維持不變。
        let discontinuous = expectedNextStart.map { abs(chunk.startTime - $0) > frameDuration / 2 } ?? true
        if discontinuous || chunk.sampleRate != sampleRate {
            pending.removeAll(keepingCapacity: true)
            origin = chunk.startTime
            framesSinceOrigin = 0
            sampleRate = chunk.sampleRate
        }
        expectedNextStart = chunk.endTime

        chunk.pcm16.withUnsafeBytes { raw in
            pending.reserveCapacity(pending.count + raw.count / 2)
            for index in 0..<(raw.count / 2) {
                pending.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
            }
        }

        var events: [Event] = []
        var offset = 0
        while pending.count - offset >= frameLength {
            var sum = 0.0
            for index in offset..<(offset + frameLength) {
                let sample = Double(pending[index])
                sum += sample * sample
            }
            let level = (sum / Double(frameLength)).squareRoot()
            let start = origin + Double(framesSinceOrigin) * frameDuration
            let end = origin + Double(framesSinceOrigin + 1) * frameDuration
            framesSinceOrigin += 1
            offset += frameLength
            if let event = classify(level: level, start: start, end: end) { events.append(event) }
        }
        pending.removeFirst(offset)
        return events
    }

    /// 處理一格：更新門檻，判斷是不是語音，必要時回報事件。
    private mutating func classify(level: Double, start: AudioTime, end: AudioTime) -> Event? {
        remember(level)
        let low = max(ordered[Int(0.10 * Double(ordered.count - 1))], 1)
        let high = max(ordered[Int(0.90 * Double(ordered.count - 1))], low * 1.5)
        currentThreshold = max(
            configuration.minimumThreshold, exp(log(low) + configuration.mix * (log(high) - log(low))))

        let minimumSpeechFrames = max(1, Int((configuration.minimumSpeech / configuration.frameDuration).rounded()))
        let silenceFrames = max(1, Int((configuration.silenceDuration / configuration.frameDuration).rounded()))

        if level > currentThreshold {
            if speechRun == 0 { speechRunStart = start }
            speechRun += 1
            silenceRun = 0
            if speaking {
                lastSpeechEnd = end
            } else if speechRun >= minimumSpeechFrames {
                speaking = true
                lastSpeechEnd = end
                return .speechStarted(at: speechRunStart)
            }
            return nil
        }

        speechRun = 0
        guard speaking else { return nil }
        silenceRun += 1
        guard silenceRun >= silenceFrames else { return nil }
        speaking = false
        silenceRun = 0
        return .paused(speechEnd: lastSpeechEnd, at: end)
    }

    /// 把這一格的音量記進時間窗；滿了就丟掉最舊的一格。
    private mutating func remember(_ level: Double) {
        let capacity = max(1, Int((configuration.window / configuration.frameDuration).rounded()))
        if recent.count < capacity {
            recent.append(level)
        } else {
            let removed = recent[oldest]
            recent[oldest] = level
            oldest = (oldest + 1) % capacity
            ordered.remove(at: Self.insertionIndex(of: removed, in: ordered))
        }
        ordered.insert(level, at: Self.insertionIndex(of: level, in: ordered))
    }

    /// `ordered` 裡第一個不小於 `value` 的位置。
    private static func insertionIndex(of value: Double, in ordered: [Double]) -> Int {
        var low = 0
        var high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
