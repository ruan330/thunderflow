import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

/// 錄音中途換了取樣率不同的裝置時，轉成這一場原本的取樣率（DESIGN.md 5.4 節）。
@Suite("取樣率轉換：中途換裝置時接著錄")
struct SampleRateConverterTests {
    /// 以 20 ms 一批送入 `seconds` 秒的 440 Hz 正弦波，回傳轉出來的全部樣本。
    private func convert(from source: Double, to target: Double, seconds: Double) throws -> [Float] {
        let converter = try SampleRateConverter(from: source, to: target)
        let input = Signal.sine(frequency: 440, sampleRate: source, duration: seconds)
        var output: [Float] = []
        let batch = Int(source / 50)
        var offset = 0
        while offset < input.count {
            let end = min(input.count, offset + batch)
            try input[offset..<end].withUnsafeBufferPointer { samples in
                try converter.convert(samples) { output.append(contentsOf: $0) }
            }
            offset = end
        }
        try converter.finish { output.append(contentsOf: $0) }
        return output
    }

    @Test(
        "各種取樣率之間轉換：分成小批送進去，轉完的總長度不變（誤差 20 ms 以內）",
        arguments: [(24_000.0, 48_000.0), (44_100, 48_000), (48_000, 16_000), (16_000, 44_100)] as [(Double, Double)])
    func preservesDuration(source: Double, target: Double) throws {
        let output = try convert(from: source, to: target, seconds: 3)

        #expect(abs(Double(output.count) / target - 3) < 0.02, "轉出 \(output.count) 個樣本")
    }

    @Test("轉完仍然是同一個音高：440 Hz 的正弦波轉完還是 440 Hz（誤差 1% 以內）")
    func preservesPitch() throws {
        let output = try convert(from: 24_000, to: 48_000, seconds: 3)
        try #require(output.count >= 120_000, "轉出 \(output.count) 個樣本")
        // 數中間 2 秒的正向過零點：440 Hz 每秒 440 次
        let middle = output[24_000..<120_000]
        var crossings = 0
        var previous = middle.first ?? 0
        for sample in middle.dropFirst() {
            if previous < 0, sample >= 0 { crossings += 1 }
            previous = sample
        }
        let frequency = Double(crossings) / (Double(middle.count) / 48_000)
        #expect(abs(frequency - 440) < 4.4, "量到 \(frequency) Hz")
    }
}
