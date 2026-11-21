import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 在乾淨的子程序裡跑一場很長的錄音，量記憶體有沒有隨時間成長。
/// 放在子程序是為了不受同一個程序裡其他測試的記憶體用量干擾。
enum LongRunScenario {
    /// - Returns: 不會返回錯誤就代表通過；不符合時印出原因並以非 0 結束。
    static func run(minutes: Int, warmupMinutes: Int, budgetKey: String, expectedSegments: Int? = nil) async throws {
        let budget = try PerfBudgets.load().maximum(budgetKey)
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2), recordsChunks: false)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)
        session.start()

        var fed = 0
        var baseline = 0.0
        for minute in 0..<minutes {
            if minute == warmupMinutes { baseline = ProcessFootprint.megabytes() }
            fed += try await feedInLockstep(session, engine: engine, seconds: 60)
        }
        let growth = ProcessFootprint.megabytes() - baseline

        do {
            try await withDeadline(.seconds(30)) { try await session.finish() }
        } catch {
            fail("finish() 沒有在 30 秒內完成")
        }

        let segments = try recordedSegments(directory)
        guard RecordingFiles.totalFrames(of: segments) == Int64(fed) else {
            fail("錄到 \(RecordingFiles.totalFrames(of: segments)) 個樣本，送入的是 \(fed) 個")
        }
        if let expectedSegments, segments.count != expectedSegments {
            fail("分段數是 \(segments.count)，應該是 \(expectedSegments)")
        }
        let captions = try JournalReader.read(directory.journalURL).sources.count
        guard captions == minutes * 30 else {
            fail("日誌裡有 \(captions) 句英文，應該是 \(minutes * 30) 句")
        }
        guard growth <= budget else {
            fail("記憶體在第 \(warmupMinutes) 分鐘之後成長了 \(growth) MB，預算是 \(budget) MB")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("LongRunScenario 失敗：\(message)\n".utf8))
        exit(1)
    }
}

/// 不變條件 6：記憶體不隨錄音時間成長。
@Suite("資源用量：長時間錄音", .timeLimit(.minutes(10)))
struct SessionResourceTests {
    @Test("30 分鐘的音訊：樣本與字幕都完整，記憶體成長在預算內")
    func thirtyMinutesStaysFlat() async {
        await #expect(processExitsWith: .success) {
            try await LongRunScenario.run(minutes: 30, warmupMinutes: 5, budgetKey: "session.memoryGrowth.megabytes.max")
        }
    }
}

/// 8 小時的長跑。會寫出約 1 GB 的暫存檔，所以要明確要求才跑：make test-soak
@Suite(
    "長跑 Soak：8 小時的錄音",
    .enabled(if: ProcessInfo.processInfo.environment["THUNDER_SOAK"] == "1", "長跑測試請用 make test-soak 執行"),
    .timeLimit(.minutes(30)))
struct SessionSoakTests {
    @Test("8 小時的音訊：樣本與字幕都完整、分成 48 段，記憶體成長在預算內")
    func eightHours() async {
        await #expect(processExitsWith: .success) {
            try await LongRunScenario.run(
                minutes: 480, warmupMinutes: 60, budgetKey: "session.soak8h.memoryGrowth.megabytes.max",
                expectedSegments: 48)
        }
    }
}

@Suite(
    "效能預算 Perf：錄音管線",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct SessionPerfTests {
    @Test("整條錄音管線（寫檔＋轉格式＋送引擎＋日誌）處理 10 分鐘的 48 kHz 音訊")
    func pipelineThroughput() async throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2), recordsChunks: false)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) { $0.sampleRate = 48_000 }
        let chunk = Signal.sine(frequency: 440, sampleRate: 48_000, duration: 0.02)
        let rounds = 30_000

        session.start()
        let start = ContinuousClock.now
        for _ in 0..<rounds {
            try chunk.withUnsafeBufferPointer { try session.process($0) }
        }
        let elapsed = ContinuousClock.now - start
        try await withDeadline(.seconds(30)) { try await session.finish() }

        #expect(try recordedFrames(directory) == Int64(rounds * chunk.count))
        let factor = 600 / elapsed.seconds
        let budget = try budgets.minimum("session.pipeline.realtimeFactor.min")
        #expect(factor >= budget, "\(Int(factor)) 倍速，預算至少 \(Int(budget)) 倍速")
    }
}
