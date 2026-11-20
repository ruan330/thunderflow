import Foundation
import ThunderCore

/// 合成測試訊號。所有訊號都有精確已知的樣本數，測試才能逐一核對。
public enum Signal {
    /// 正弦波。`startingAtSample` 讓分段產生的波形可以首尾相接。
    public static func sine(
        frequency: Double,
        sampleRate: Double,
        duration: TimeInterval,
        amplitude: Float = 0.5,
        startingAtSample start: Int = 0
    ) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        let step = 2.0 * Double.pi * frequency / sampleRate
        return (0..<count).map { amplitude * Float(sin(step * Double(start + $0))) }
    }

    public static func constant(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    public static func silence(count: Int) -> [Float] {
        constant(0, count: count)
    }

    // MARK: 序號訊號：每個樣本的值就是它的序號，用來檢查「一個不少、順序不亂」

    /// 序號每到這個數就從 0 重新開始，確保 Float 能精確表示每個值。
    public static let sequenceModulus = 1_000_003

    /// 第 `start` 個樣本起的 `count` 個序號樣本。只用在不經過 16-bit 量化的地方（例如 RingBuffer）。
    public static func sequence(from start: Int, count: Int) -> [Float] {
        (0..<count).map { Float((start + $0) % sequenceModulus) }
    }

    /// 檢查 `samples` 是不是從 `start` 開始的序號訊號。回傳第一個不符的位置；完全相符回傳 nil。
    public static func firstMismatch(in samples: [Float], sequenceFrom start: Int) -> Int? {
        for (offset, sample) in samples.enumerated() where sample != Float((start + offset) % sequenceModulus) {
            return offset
        }
        return nil
    }

    // MARK: 16-bit PCM

    public static func int16Samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }

    public static func int16Samples(of chunks: [AudioChunk]) -> [Int16] {
        chunks.flatMap { int16Samples($0.pcm16) }
    }

    /// 訊號由正轉負或由負轉正的次數（剛好是 0 的樣本不算）。頻率 f 的正弦波每秒約有 2f 次。
    public static func zeroCrossings(_ samples: [Int16]) -> Int {
        var crossings = 0
        var lastSign = 0
        for sample in samples where sample != 0 {
            let sign = sample > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign { crossings += 1 }
            lastSign = sign
        }
        return crossings
    }
}
