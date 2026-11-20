import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 不變條件 1：不管引擎怎麼壞，錄到的樣本數都等於輸入的樣本數。
@Suite("引擎故障時，錄音不受影響", .timeLimit(.minutes(2)))
struct EngineFaultTests {
    @Test("各種故障下：60 秒的音訊一個樣本不少，送音訊不會被拖住，結束也不會卡住", arguments: ScriptedEngine.Behavior.allFaults)
    func recordingSurvives(_ behavior: ScriptedEngine.Behavior) async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(behavior)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) { $0.segmentDuration = 5 }
        let fed = LockedValue(0)

        session.start()
        // 60 秒的音訊，純處理只需要一瞬間；被引擎拖住的話會超過時限
        let fedInTime = completesWithin(.seconds(20)) {
            if let frames = try? feed(session, seconds: 60) { fed.withValue { $0 = frames } }
        }
        #expect(fedInTime, "送音訊的呼叫被引擎拖住了")
        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }

        #expect(fed.value == 60 * 16_000)
        #expect(try recordedFrames(directory) == Int64(fed.value))
        #expect(try recordedSegments(directory).count == 12)
        #expect(abs(meta.durationSeconds - 60) < 0.001)
        #expect(meta.state == .finalizing)
        #expect(meta.integrity.isRecordingComplete)
        #expect(try directory.loadMeta() == meta)
    }

    @Test("引擎完全卡住：超出等待區的音訊記成缺口（等待區 10 秒，60 秒的音訊至少有 50 秒沒翻譯到）")
    func stalledEngineLeavesGaps() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.stalled)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) {
            $0.engineBufferDuration = 10
        }

        session.start()
        try feed(session, seconds: 60)
        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }

        let gaps = AudioGap.coalesced(try JournalReader.read(directory.journalURL).gaps)
        let untranslated = gaps.reduce(0) { $0 + $1.duration }
        #expect(untranslated >= 49.5 && untranslated <= 60.001)
        #expect(abs((gaps.first?.from.seconds ?? -1) - 0) < 0.25)
        #expect(gaps.allSatisfy { $0.reason == .backpressure || $0.reason == .engineStopped })
        #expect(gaps.allSatisfy { $0.to.seconds <= 60.001 })
        #expect(abs(meta.integrity.untranslatedSeconds - untranslated) < 0.5)
        #expect(engine.receivedChunkCount == 0)
    }

    @Test("引擎中途結束（例如 API Key 失效）：錄音繼續，之後的音訊記成缺口")
    func engineEndingEarlyDoesNotStopRecording() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.endsEarly(after: 5))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        #expect(session.isEngineRunning)
        try feed(session, seconds: 8)
        // 等場次發現引擎已經結束，再送後面的音訊
        #expect(waitUntil { !session.isEngineRunning })
        let stoppedAt = session.audioTime.seconds
        try feed(session, seconds: 50)
        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }

        #expect(try recordedFrames(directory) == Int64(58 * 16_000))
        #expect(abs(meta.durationSeconds - 58) < 0.001)

        let gaps = AudioGap.coalesced(try JournalReader.read(directory.journalURL).gaps)
        let afterStop = gaps.filter { $0.reason == .engineStopped }
        let untranslatedAfterStop = afterStop.reduce(0) { $0 + $1.duration }
        #expect(untranslatedAfterStop >= 49.5 && untranslatedAfterStop <= 50.5)
        #expect(abs((afterStop.first?.from.seconds ?? -1) - stoppedAt) < 0.5)
        #expect(abs((afterStop.last?.to.seconds ?? -1) - 58) < 0.25)
        #expect(meta.integrity.untranslatedSeconds >= 49.5)
    }

    @Test("引擎不收尾：結束時最多等設定的時間就放棄，不會無限期等下去")
    func finishGivesUpOnAHangingEngine() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.neverEnds)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) {
            $0.engineDrainTimeout = .milliseconds(300)
        }

        session.start()
        try feedInLockstep(session, engine: engine, seconds: 6)
        let start = ContinuousClock.now
        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed >= .milliseconds(250), "應該先給引擎收尾的時間")
        #expect(elapsed < .seconds(3))
        #expect(meta.state == .finalizing)
        // 引擎在被放棄之前送出的字幕都有寫進日誌
        let journal = try JournalReader.read(directory.journalURL)
        #expect(journal.sources.map(\.text) == (1...3).map(ScriptedEngine.sourceText))
        #expect(waitUntil { engine.hasFinished }, "放棄等待後應該取消引擎")
    }

    @Test("引擎消化得慢：錄音完整，來不及消化的部分記成缺口，消化到的部分字幕照常")
    func slowEngineDropsOnlyWhatItCannotKeepUpWith() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.slow(perChunk: .milliseconds(2)))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) {
            $0.engineBufferDuration = 2
            $0.engineDrainTimeout = .seconds(5)
        }

        session.start()
        let fed = try feed(session, seconds: 30)
        let meta = try await withDeadline(.seconds(20)) { try await session.finish() }

        #expect(try recordedFrames(directory) == Int64(fed))
        let journal = try JournalReader.read(directory.journalURL)
        let untranslated = AudioGap.coalesced(journal.gaps).reduce(0) { $0 + $1.duration }
        // 引擎實際消化的音訊，加上記成缺口的音訊，剛好等於整場錄音（誤差不超過一包）
        #expect(abs(engine.receivedDuration + untranslated - 30) < 0.25)
        #expect(abs(meta.integrity.untranslatedSeconds - untranslated) < 0.25)
        #expect(journal.gaps.allSatisfy { $0.reason == .backpressure })
    }
}
