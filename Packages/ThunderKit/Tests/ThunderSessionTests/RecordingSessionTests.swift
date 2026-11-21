import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

@Suite("RecordingSession：一場錄音的正常流程", .timeLimit(.minutes(2)))
struct RecordingSessionTests {
    @Test("建立場次後，資料夾裡立刻有狀態為 recording 的 session.json 和空的日誌")
    func creationWritesInitialState() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))

        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        let meta = try directory.loadMeta()
        #expect(meta.state == .recording)
        #expect(!meta.recovered)
        #expect(meta.title == "測試場次")
        #expect(meta.startedAt == Fixture.startedAt)
        #expect(meta.source == "合成音訊")
        #expect(meta.engine == "scripted")
        #expect(meta.durationSeconds == 0)
        #expect(try JournalReader.read(directory.journalURL).entries.isEmpty)
        #expect(session.audioTime == .zero)
        #expect(!session.isPaused)
    }

    @Test("完整跑一場：錄音一個樣本不少，字幕依序寫進日誌，結束後狀態是 finalizing")
    func completeSession() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        let fed = try await feedInLockstep(session, engine: engine, seconds: 30)
        let meta = try await withDeadline(.seconds(30)) { try await session.finish() }

        // 錄音
        #expect(try recordedFrames(directory) == Int64(fed))
        #expect(fed == 30 * 16_000)

        // 基本資料
        #expect(meta.state == .finalizing)
        #expect(!meta.recovered)
        #expect(abs(meta.durationSeconds - 30) < 0.001)
        #expect(abs(meta.billedAudioSeconds - 30) < 0.5)
        #expect(meta.integrity.isRecordingComplete)
        #expect(meta.integrity.untranslatedSeconds == 0)
        #expect(try directory.loadMeta() == meta)

        // 日誌：15 句英文、15 句中文，照順序，時間只增不減，而且都在錄音長度之內
        let journal = try JournalReader.read(directory.journalURL)
        #expect(journal.sources.map(\.text) == (1...15).map(ScriptedEngine.sourceText))
        #expect(journal.translations.map(\.text) == (1...15).map(ScriptedEngine.translationText))
        #expect(journal.sources.map(\.at) == journal.sources.map(\.at).sorted())
        #expect(journal.latestTime.seconds <= meta.durationSeconds + 0.001)
        #expect(journal.gaps.isEmpty)
        #expect(!journal.hasTruncatedTail)
        #expect(journal.skippedLineCount == 0)
    }

    @Test("送給引擎的音訊：24 kHz、每包 200 ms、一包接一包、涵蓋整場錄音")
    func engineReceivesContiguousAudio() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, _) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 12)
        try await withDeadline(.seconds(30)) { try await session.finish() }

        let chunks = engine.receivedChunks
        #expect(engine.runCount == 1)
        #expect(chunks.first?.startTime == .zero)
        #expect(chunks.allSatisfy { $0.sampleRate == 24_000 })
        #expect(chunks.dropLast().allSatisfy { $0.frameCount == 4_800 })
        #expect(largestSeam(in: chunks) < 1e-6)
        #expect(abs(engine.receivedDuration - 12) < 0.05)
    }

    @Test("引擎拿到場次設定的語言")
    func engineReceivesConfig() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, _) = try Fixture.makeSession(in: tmp.url, engine: engine) {
            $0.engine = EngineConfig(sourceLanguage: "en", targetLanguage: "ja")
        }

        session.start()
        try await withDeadline(.seconds(30)) { try await session.finish() }

        #expect(engine.lastConfig == EngineConfig(sourceLanguage: "en", targetLanguage: "ja"))
    }

    @Test("音訊時間跟著送入的樣本前進")
    func audioTimeAdvances() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, _) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 2)))

        session.start()
        try feed(session, seconds: 1.5)

        #expect(abs(session.audioTime.seconds - 1.5) < 1e-9)
    }

    @Test("錄音依設定的長度分段")
    func rotatesSegments() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) { $0.segmentDuration = 2 }

        session.start()
        try feed(session, seconds: 9)
        try await withDeadline(.seconds(30)) { try await session.finish() }

        #expect(try recordedSegments(directory).map(\.frameCount) == [32_000, 32_000, 32_000, 32_000, 16_000])
    }

    @Test("結束後不能再送音訊；重複結束會得到同一份結果")
    func finishIsFinal() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        let fed = try feed(session, seconds: 2)
        let first = try await withDeadline(.seconds(30)) { try await session.finish() }
        let second = try await withDeadline(.seconds(30)) { try await session.finish() }

        #expect(first == second)
        #expect(throws: RecordingSessionError.alreadyFinished) { try feed(session, seconds: 1) }
        #expect(try recordedFrames(directory) == Int64(fed))
        #expect(!session.isEngineRunning)
    }

    @Test("沒有任何音訊就結束：長度為 0，不留下空的錄音檔")
    func emptySession() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 2)))

        session.start()
        let meta = try await withDeadline(.seconds(30)) { try await session.finish() }

        #expect(meta.state == .finalizing)
        #expect(meta.durationSeconds == 0)
        #expect(try recordedSegments(directory).isEmpty)
    }

    @Test("48 kHz 的來源也一樣：錄音保留原取樣率，送引擎的是 24 kHz")
    func worksAt48kHz() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) { $0.sampleRate = 48_000 }

        session.start()
        let fed = try await feedInLockstep(session, engine: engine, seconds: 4, sampleRate: 48_000)
        let meta = try await withDeadline(.seconds(30)) { try await session.finish() }

        let segments = try recordedSegments(directory)
        #expect(segments.map(\.sampleRate) == [48_000])
        #expect(RecordingFiles.totalFrames(of: segments) == Int64(fed))
        #expect(abs(meta.durationSeconds - 4) < 0.001)
        #expect(engine.receivedChunks.allSatisfy { $0.sampleRate == 24_000 })
        #expect(abs(engine.receivedDuration - 4) < 0.05)
    }
}

@Suite("RecordingSession：暫停與重點標記", .timeLimit(.minutes(2)))
struct PauseAndMarkerTests {
    @Test("暫停期間的聲音不錄、不送引擎，音訊時間不前進；繼續之後接著錄")
    func pauseSkipsAudio() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)

        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 10, level: 0.25)

        session.pause()
        #expect(session.isPaused)
        let pausedAt = session.audioTime
        try feed(session, seconds: 5, level: 0.75)
        #expect(session.audioTime == pausedAt)

        session.resume()
        #expect(!session.isPaused)
        try await feedInLockstep(session, engine: engine, seconds: 10, level: -0.25)
        let meta = try await withDeadline(.seconds(30)) { try await session.finish() }

        // 錄音只有 20 秒：前 10 秒是 0.25，後 10 秒是 -0.25，暫停時的 0.75 完全不在裡面
        #expect(abs(meta.durationSeconds - 20) < 0.001)
        let samples = try recordedSamples(directory)
        #expect(samples.count == 20 * 16_000)
        guard samples.count == 20 * 16_000 else { return }
        #expect(samples[..<160_000].allSatisfy { abs($0 - 0.25) < 1e-3 })
        #expect(samples[160_000...].allSatisfy { abs($0 + 0.25) < 1e-3 })

        // 引擎拿到的也是 20 秒，而且時間軸沒有因為暫停而跳號
        #expect(abs(engine.receivedDuration - 20) < 0.05)
        #expect(largestSeam(in: engine.receivedChunks) < 1e-6)

        // 日誌記下暫停與繼續，兩者的音訊時間都是 10 秒
        let journal = try JournalReader.read(directory.journalURL)
        let pauses = journal.entries.compactMap { entry -> AudioTime? in
            if case .paused(let time) = entry { time } else { nil }
        }
        let resumes = journal.entries.compactMap { entry -> AudioTime? in
            if case .resumed(let time) = entry { time } else { nil }
        }
        #expect(pauses.count == 1 && resumes.count == 1)
        #expect(abs((pauses.first?.seconds ?? -1) - 10) < 0.001)
        #expect(abs((resumes.first?.seconds ?? -1) - 10) < 0.001)
        #expect(journal.gaps.isEmpty)
    }

    @Test("重複暫停或重複繼續不會多記")
    func pauseAndResumeAreIdempotent() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 2)))

        session.start()
        try feed(session, seconds: 1)
        session.resume()
        session.pause()
        session.pause()
        session.resume()
        session.resume()
        try await withDeadline(.seconds(30)) { try await session.finish() }

        let entries = try JournalReader.read(directory.journalURL).entries
        #expect(entries.filter { if case .paused = $0 { true } else { false } }.count == 1)
        #expect(entries.filter { if case .resumed = $0 { true } else { false } }.count == 1)
    }

    @Test("重點標記記在當下的音訊時間")
    func markersUseAudioTime() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 2)))

        session.start()
        try feed(session, seconds: 3)
        session.mark()
        try feed(session, seconds: 2)
        session.mark()
        try await withDeadline(.seconds(30)) { try await session.finish() }

        let markers = try JournalReader.read(directory.journalURL).markers
        #expect(markers.count == 2)
        guard markers.count == 2 else { return }
        #expect(abs(markers[0].seconds - 3) < 0.001)
        #expect(abs(markers[1].seconds - 5) < 0.001)
    }
}
