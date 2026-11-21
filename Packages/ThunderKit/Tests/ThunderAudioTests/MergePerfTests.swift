import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

/// 效能預算：結束處理的合併錄音（DESIGN.md 9.8 節）。
@Suite(
    "效能預算 Perf：合併錄音",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct MergePerfTests {
    @Test("RecordingMerger：10 分鐘的 CAF 分段（48 kHz）合併成 m4a，換算成每小時錄音要花的時間")
    func mergeThroughput() throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let audio = tmp.url.appendingPathComponent("audio", isDirectory: true)
        let recorder = try SegmentedRecorder(directory: audio, sampleRate: 48_000, segmentDuration: 120)
        // 像語音的訊號：編碼器的速度和內容有關，純音反而比語音慢很多，不能代表實際的錄音。
        // 實測（M1 Max）：這個訊號每秒約 450 倍速，真正的語音約 470 倍速，兩個純音相加只有約 310 倍速
        let loop = Self.speechLike(seconds: 5, sampleRate: 48_000)
        for _ in 0..<120 {
            for offset in stride(from: 0, to: loop.count, by: 960) {
                try loop[offset..<offset + 960].withUnsafeBufferPointer { try recorder.append($0) }
            }
        }
        try recorder.close()
        let segments = try RecordingFiles.segments(in: audio)
        let target = tmp.url.appendingPathComponent("recording.m4a")

        var merged = 0.0
        let elapsed = try Perf.measure(runs: 3) {
            try? FileManager.default.removeItem(at: target)
            merged = try RecordingMerger.merge(segments: segments, to: target)
        }

        #expect(segments.count == 5)
        #expect(abs(merged - 600) < 0.2)
        let perHour = elapsed.seconds * 6
        let budget = try budgets.maximum("finalize.audioPerRecordedHour.seconds.max")
        print("量測：合併錄音每小時 \(perHour) 秒（預算 \(budget) 秒）")
        #expect(perHour <= budget, "每小時錄音 \(perHour) 秒（10 分鐘花了 \(elapsed)），預算 \(budget) 秒")
    }

    /// 像語音的合成訊號：基頻 110–150 Hz 的諧波（依共振峰加權）、每秒 4 個音節的起伏、說 4 秒停 1 秒、很小的底噪。
    private static func speechLike(seconds: Double, sampleRate: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        var seed: UInt32 = 12_345
        for index in 0..<count {
            let time = Double(index) / sampleRate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Double(seed >> 9) / Double(1 << 23) - 0.5) * 0.002
            guard time.truncatingRemainder(dividingBy: 5) < 4 else {
                samples[index] = Float(noise)
                continue
            }
            let fundamental = 130 + 20 * sin(2 * .pi * 0.7 * time)
            phase += 2 * .pi * fundamental / sampleRate
            let envelope = pow(max(0, sin(2 * .pi * 4 * time)), 2)
            var voiced = 0.0
            for harmonic in 1...24 {
                let frequency = Double(harmonic) * fundamental
                let weight =
                    exp(-pow((frequency - 600) / 300, 2)) + 0.6 * exp(-pow((frequency - 1_700) / 400, 2))
                    + 0.3 * exp(-pow((frequency - 2_700) / 500, 2))
                voiced += weight * sin(Double(harmonic) * phase)
            }
            samples[index] = Float(0.15 * envelope * voiced + noise)
        }
        return samples
    }
}
