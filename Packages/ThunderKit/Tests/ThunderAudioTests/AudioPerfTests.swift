import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

/// 效能預算測試。每個測試都同時檢查「事情真的有做完」，避免空轉也算通過。
@Suite(
    "效能預算 Perf：音訊元件",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized)
struct AudioPerfTests {
    @Test("RingBuffer：一小時的音訊（48 kHz、10 ms 一包）來回一趟")
    func ringThroughput() throws {
        let budgets = try PerfBudgets.load()
        let ring = RingBuffer(minimumCapacity: 48_000)
        let chunk = Signal.sine(frequency: 440, sampleRate: 48_000, duration: 0.01)
        var scratch = [Float](repeating: 0, count: chunk.count)
        let rounds = 360_000
        var transferred = 0

        let elapsed = Perf.measure(runs: 5) {
            transferred = 0
            for _ in 0..<rounds {
                chunk.withUnsafeBufferPointer { _ = ring.write($0) }
                transferred += scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            }
        }

        #expect(transferred == rounds * chunk.count)
        let factor = 3_600 / elapsed.seconds
        let budget = try budgets.minimum("ring.throughput.realtimeFactor.min")
        #expect(factor >= budget, "\(Int(factor)) 倍速，預算至少 \(Int(budget)) 倍速")
    }

    @Test("SegmentedRecorder：寫入 10 分鐘的音訊（48 kHz、20 ms 一包）")
    func recorderThroughput() throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let chunk = Signal.sine(frequency: 440, sampleRate: 48_000, duration: 0.02)
        let rounds = 30_000

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: 48_000)
        let start = ContinuousClock.now
        for _ in 0..<rounds {
            try chunk.withUnsafeBufferPointer { try recorder.append($0) }
        }
        try recorder.close()
        let elapsed = ContinuousClock.now - start

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(RecordingFiles.totalFrames(of: segments) == Int64(rounds * chunk.count))
        let factor = 600 / elapsed.seconds
        let budget = try budgets.minimum("recorder.throughput.realtimeFactor.min")
        #expect(factor >= budget, "\(Int(factor)) 倍速，預算至少 \(Int(budget)) 倍速")
    }

    @Test("EngineAudioEncoder：轉換 10 分鐘的音訊（48 kHz 轉 24 kHz）")
    func encoderThroughput() throws {
        let budgets = try PerfBudgets.load()
        let chunk = Signal.sine(frequency: 440, sampleRate: 48_000, duration: 0.02)
        let rounds = 30_000
        var frames = 0

        let encoder = try EngineAudioEncoder(sourceRate: 48_000)
        let start = ContinuousClock.now
        for _ in 0..<rounds {
            for output in try chunk.withUnsafeBufferPointer({ try encoder.encode($0) }) {
                frames += output.frameCount
            }
        }
        if let tail = try encoder.finish() { frames += tail.frameCount }
        let elapsed = ContinuousClock.now - start

        #expect(abs(Double(frames) / 24_000 - 600) < 0.02)
        let factor = 600 / elapsed.seconds
        let budget = try budgets.minimum("encoder.throughput.realtimeFactor.min")
        #expect(factor >= budget, "\(Int(factor)) 倍速，預算至少 \(Int(budget)) 倍速")
    }
}
