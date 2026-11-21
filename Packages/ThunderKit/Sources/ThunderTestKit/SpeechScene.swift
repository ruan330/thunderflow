import Foundation
import ThunderCore

extension Signal {
    /// 音節的長度：前 120 ms 有聲，後 60 ms 變小聲。
    public static let syllableDuration: TimeInterval = 0.18
    public static let syllableVoicedDuration: TimeInterval = 0.12

    /// 像說話的合成訊號：220 Hz 的音，音量照「音節」起伏。
    ///
    /// 用來測停頓偵測：音節之間變小聲只有 60 ms，不應該被當成停頓。
    /// 開頭與結尾一定是有聲的部分（最後 70 ms 不會變小聲），所以「這段語音的起訖」就是整段的起訖。
    ///
    /// - Parameters:
    ///   - amplitude: 有聲部分的振幅（0–1）。有聲部分的音量（RMS，16-bit 振幅單位）約是 amplitude × 0.707 × 32767。
    ///   - dipRatio: 變小聲時的振幅是有聲部分的幾分之幾。
    public static func speechLike(
        sampleRate: Double,
        duration: TimeInterval,
        amplitude: Float = 0.2,
        dipRatio: Float = 0.25
    ) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        let step = 2.0 * Double.pi * 220 / sampleRate
        let tailStart = duration - 0.07
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let withinSyllable = time.truncatingRemainder(dividingBy: syllableDuration)
            let isDip = withinSyllable >= syllableVoicedDuration && time < tailStart
            return (isDip ? amplitude * dipRatio : amplitude) * Float(sin(step * Double(index)))
        }
    }

    /// 固定音量的白噪音。同一個 `seed` 每次產生同樣的樣本，所以測試結果固定。
    /// - Parameter rms: 音量（RMS，16-bit 振幅單位）。例如現場收音的底噪大約是 500。
    public static func noise(rms: Double, count: Int, seed: UInt64 = 1) -> [Float] {
        // 均勻分布在 [-a, a] 的雜訊，RMS 是 a / √3
        let amplitude = Float(rms * 3.0.squareRoot() / 32767.0)
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)  // 0..<1
            return amplitude * (2 * unit - 1)
        }
    }

    /// 兩個訊號相加（長度取較短的）。
    public static func mix(_ first: [Float], _ second: [Float]) -> [Float] {
        zip(first, second).map { $0 + $1 }
    }

    /// 音量（RMS，16-bit 振幅單位）。
    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot() * 32767
    }

    /// 轉成 16-bit PCM（little-endian）。超出範圍的樣本會被限幅。
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let scaled = (Double(sample) * 32767).rounded()
            let value = Int16(max(-32768, min(32767, scaled)))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// 切成一包一包、送給引擎的音訊。最後不滿一包的也會送出。
    public static func audioChunks(
        _ samples: [Float],
        sampleRate: Int = 24_000,
        chunkDuration: TimeInterval = 0.2,
        startTime: AudioTime = .zero
    ) -> [AudioChunk] {
        let framesPerChunk = max(1, Int((chunkDuration * Double(sampleRate)).rounded()))
        var chunks: [AudioChunk] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + framesPerChunk, samples.count)
            chunks.append(
                AudioChunk(
                    pcm16: pcm16(Array(samples[offset..<end])), sampleRate: sampleRate,
                    startTime: startTime + Double(offset) / Double(sampleRate)))
            offset = end
        }
        return chunks
    }
}

/// 一段「說話、停頓、再說話」的測試音訊，連同正確答案：每段語音的起訖時間。
public struct SpeechScene: Sendable {
    public enum Part: Sendable, Equatable {
        /// 像說話的聲音（`Signal.speechLike`）。
        case speech(TimeInterval)
        /// 沒有人說話（只剩底噪）。
        case silence(TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .speech(let duration), .silence(let duration): duration
            }
        }
    }

    public let sampleRate: Int
    public let samples: [Float]
    /// 每段語音的起訖（秒，從這段音訊的開頭算起）。相鄰的 `.speech` 算成同一段。
    public let speechIntervals: [ClosedRange<TimeInterval>]

    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }

    /// - Parameters:
    ///   - amplitude: 語音有聲部分的振幅（0–1）。
    ///   - noiseRMS: 整段都有的底噪音量（RMS，16-bit 振幅單位）。0 表示數位靜音。
    public init(
        _ parts: [Part],
        sampleRate: Int = 24_000,
        amplitude: Float = 0.2,
        noiseRMS: Double = 0,
        seed: UInt64 = 1
    ) {
        var samples: [Float] = []
        var intervals: [ClosedRange<TimeInterval>] = []
        var time: TimeInterval = 0
        for part in parts {
            let count = Int((part.duration * Double(sampleRate)).rounded())
            switch part {
            case .speech(let duration):
                samples += Signal.speechLike(sampleRate: Double(sampleRate), duration: duration, amplitude: amplitude)
                if let last = intervals.last, abs(last.upperBound - time) < 1e-9 {
                    intervals[intervals.count - 1] = last.lowerBound...(time + duration)
                } else {
                    intervals.append(time...(time + duration))
                }
            case .silence:
                samples += Signal.silence(count: count)
            }
            time += part.duration
        }
        if noiseRMS > 0 {
            samples = Signal.mix(samples, Signal.noise(rms: noiseRMS, count: samples.count, seed: seed))
        }
        self.sampleRate = sampleRate
        self.samples = samples
        self.speechIntervals = intervals
    }

    private init(sampleRate: Int, samples: [Float], speechIntervals: [ClosedRange<TimeInterval>]) {
        self.sampleRate = sampleRate
        self.samples = samples
        self.speechIntervals = speechIntervals
    }

    /// 把兩段接起來（取樣率要相同）。後一段的語音起訖會跟著往後移。用來做「環境中途改變」的音訊。
    public static func + (first: SpeechScene, second: SpeechScene) -> SpeechScene {
        precondition(first.sampleRate == second.sampleRate, "兩段的取樣率要相同")
        let offset = first.duration
        return SpeechScene(
            sampleRate: first.sampleRate, samples: first.samples + second.samples,
            speechIntervals: first.speechIntervals
                + second.speechIntervals.map { ($0.lowerBound + offset)...($0.upperBound + offset) })
    }

    public func chunks(chunkDuration: TimeInterval = 0.2, startTime: AudioTime = .zero) -> [AudioChunk] {
        Signal.audioChunks(samples, sampleRate: sampleRate, chunkDuration: chunkDuration, startTime: startTime)
    }
}
