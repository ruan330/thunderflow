import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 效能預算測試。每個測試都同時檢查「事情真的有做完」，避免空轉也算通過。
@Suite(
    "效能預算 Perf：引擎的各個部分",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct EnginePerfTests {
    @Test("PauseDetector：10 分鐘的音訊（24 kHz、200 ms 一包、有底噪）")
    func pauseDetectorThroughput() throws {
        let budgets = try PerfBudgets.load()
        // 30 秒的場景（說 4 秒、停 1 秒，共 6 輪）重複 20 次，時間一路接下去
        let scene = SpeechScene(Array(repeating: [SpeechScene.Part.speech(4), .silence(1)], count: 6).flatMap { $0 }, noiseRMS: 500)
        let rounds = 20
        let chunks = (0..<rounds).flatMap { scene.chunks(startTime: AudioTime(seconds: Double($0) * scene.duration)) }
        var pauses = 0

        let elapsed = Perf.measure(runs: 5) {
            var detector = PauseDetector()
            pauses = 0
            for chunk in chunks {
                for case .paused in detector.process(chunk) { pauses += 1 }
            }
        }

        #expect(pauses == rounds * 6)
        let factor = Double(rounds) * scene.duration / elapsed.seconds
        let budget = try budgets.minimum("engines.pauseDetector.realtimeFactor.min")
        #expect(factor >= budget, "\(Int(factor)) 倍速，預算至少 \(Int(budget)) 倍速")
    }

    @Test("Segmenter：8 小時的增量文字，每筆的處理時間不隨場次變長")
    func segmenterThroughput() throws {
        let budgets = try PerfBudgets.load()
        // 每秒 3 個字、每 12 個字一句、每句之後停頓一次：8 小時共 86,400 個字、7,200 句
        let wordCount = 8 * 3_600 * 3
        var sentences = 0
        var deltas = 0

        let elapsed = Perf.measure(runs: 5) {
            var segmenter = Segmenter()
            sentences = 0
            deltas = 0
            var now = 0.0
            func count(_ outputs: [Segmenter.Output]) {
                for case .finished in outputs { sentences += 1 }
            }
            for index in 0..<wordCount {
                now += 1.0 / 3
                let endsSentence = index % 12 == 11
                count(segmenter.receive(endsSentence ? " word." : " word", at: now))
                deltas += 1
                if endsSentence {
                    count(segmenter.pauseDetected(speechEnd: now - 0.1, at: now + 0.2))
                    count(segmenter.advance(to: now + 0.3))
                }
            }
            count(segmenter.flush(at: now + 10))
        }

        #expect(sentences == wordCount / 12)
        let microseconds = elapsed.seconds * 1_000_000 / Double(deltas)
        let budget = try budgets.maximum("engines.segmenter.microsecondsPerDelta.max")
        #expect(microseconds <= budget, "每筆 \(microseconds) 微秒，預算 \(budget) 微秒")
    }
}
