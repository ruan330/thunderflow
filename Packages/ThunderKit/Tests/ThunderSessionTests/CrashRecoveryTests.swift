import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 在子程序裡執行、會被 SIGKILL 殺掉的劇本。參數透過環境變數傳入。
enum CrashScenario {
    static let directoryKey = "THUNDER_CRASH_DIR"
    static let killAfterKey = "THUNDER_CRASH_KILL_MS"
    static let progressFileName = "progress"

    static func prepare(directory: URL, killAfterMilliseconds: Int) {
        setenv(directoryKey, directory.path, 1)
        setenv(killAfterKey, String(killAfterMilliseconds), 1)
    }

    private static func parameters() -> (root: URL, killAfterMilliseconds: Int) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[directoryKey], let delay = environment[killAfterKey].flatMap({ Int($0) }) else {
            exit(64)
        }
        return (URL(fileURLWithPath: path), delay)
    }

    private static func scheduleKill(afterMilliseconds delay: Int) {
        Thread.detachNewThread {
            usleep(useconds_t(delay * 1_000))
            kill(getpid(), SIGKILL)
        }
    }

    /// 開始一場錄音並全速送入音訊，直到被殺掉。
    /// 每送完一包，就把「已經送入的樣本數」寫進 progress 檔，讓測試知道被殺之前至少處理到哪裡。
    static func recordUntilKilled() throws {
        let (root, delay) = parameters()
        let engine = ScriptedEngine(.captions(every: 0.5), recordsChunks: false)
        let (session, _) = try Fixture.makeSession(in: root, engine: engine) { $0.segmentDuration = 2 }
        session.start()

        let progress = open(root.appendingPathComponent(progressFileName).path, O_CREAT | O_WRONLY, 0o644)
        guard progress >= 0 else { exit(65) }
        let chunk = Signal.constant(0.25, count: 320)
        var frames: Int64 = 0

        scheduleKill(afterMilliseconds: delay)
        let giveUp = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < giveUp {
            try chunk.withUnsafeBufferPointer { try session.process($0) }
            frames += Int64(chunk.count)
            _ = withUnsafeBytes(of: frames) { pwrite(progress, $0.baseAddress, $0.count, 0) }
        }
        exit(66) // 沒有被殺掉：測試會因為結束方式不符而失敗
    }

    /// 反覆覆寫 session.json，直到被殺掉。
    static func rewriteMetaUntilKilled() throws {
        let (root, delay) = parameters()
        let directory = SessionDirectory(url: root.appendingPathComponent("session", isDirectory: true))
        try directory.create()
        var meta = SessionMeta(title: String(repeating: "很長的標題", count: 400), startedAt: Fixture.startedAt)
        try directory.saveMeta(meta)

        scheduleKill(afterMilliseconds: delay)
        let giveUp = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < giveUp {
            meta.durationSeconds += 1
            try directory.saveMeta(meta)
        }
        exit(66)
    }

    static func reportedFrames(in root: URL) throws -> Int64 {
        let data = try Data(contentsOf: root.appendingPathComponent(progressFileName))
        guard data.count >= 8 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    }
}

/// 不變條件 2：任意時間點被強制結束，重啟後錄音和字幕都救得回來。
///
/// 用環境變數把參數傳給子程序，所以這組測試必須一個一個跑。
@Suite("當機安全：錄音中被 kill -9", .serialized, .timeLimit(.minutes(2)))
struct CrashRecoveryTests {
    @Test("任意時間點被殺掉：分段都打得開、日誌讀得回來、已處理的聲音最多少 0.1 秒，而且能復原", arguments: [15, 40, 90, 160])
    func killedMidRecording(afterMilliseconds: Int) async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        CrashScenario.prepare(directory: tmp.url, killAfterMilliseconds: afterMilliseconds)

        await #expect(processExitsWith: .signal(SIGKILL)) {
            try CrashScenario.recordUntilKilled()
        }

        // 重啟後找得到這一場，狀態還停在 recording
        let interrupted = try SessionRecovery.findInterrupted(in: tmp.url)
        #expect(interrupted.count == 1)
        let found = try #require(interrupted.first)
        #expect(found.meta.state == .recording)
        #expect(found.meta.title == "測試場次")

        // 每個分段都打得開，而且已經回報「處理完」的聲音都在檔案裡（最多少 0.1 秒）
        let segments = try recordedSegments(found.directory)
        #expect(!segments.isEmpty)
        #expect(found.segmentCount == segments.count)
        let recorded = RecordingFiles.totalDuration(of: segments)
        let reported = Double(try CrashScenario.reportedFrames(in: tmp.url)) / Fixture.sampleRate
        #expect(reported > 0, "子程序在被殺掉之前沒有處理任何音訊")
        #expect(recorded >= reported - 0.1, "回報已處理 \(reported) 秒，檔案裡只有 \(recorded) 秒")
        #expect(abs(found.recordedDuration - recorded) < 0.001)

        // 日誌讀得回來，而且沒有任何紀錄的時間超前於已經落地的錄音
        let journal = try JournalReader.read(found.directory.journalURL)
        #expect(journal.skippedLineCount == 0)
        #expect(journal.latestTime.seconds <= recorded + 0.1)

        // 復原：狀態進入 finalizing、標記為已復原、長度是實際救回的長度，而且不會被重複復原
        let recovered = try SessionRecovery.recover(found)
        #expect(recovered.state == .finalizing)
        #expect(recovered.recovered)
        #expect(abs(recovered.durationSeconds - recorded) < 0.001)
        #expect(try found.directory.loadMeta() == recovered)
        #expect(try SessionRecovery.findInterrupted(in: tmp.url).isEmpty)
    }

    @Test("覆寫 session.json 的途中被殺掉：留下來的一定是完整的檔", arguments: [10, 35, 80])
    func killedWhileRewritingMeta(afterMilliseconds: Int) async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        CrashScenario.prepare(directory: tmp.url, killAfterMilliseconds: afterMilliseconds)

        await #expect(processExitsWith: .signal(SIGKILL)) {
            try CrashScenario.rewriteMetaUntilKilled()
        }

        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("session", isDirectory: true))
        let meta = try directory.loadMeta()
        #expect(meta.title == String(repeating: "很長的標題", count: 400))
        #expect(meta.durationSeconds >= 0)
    }
}

@Suite("SessionRecovery：找出沒有正常結束的場次")
struct SessionRecoveryTests {
    private func makeSessionFolder(in root: URL, state: SessionState, seconds: Double) throws -> SessionDirectory {
        let meta = SessionMeta(title: "\(state)", startedAt: Fixture.startedAt, state: state)
        let directory = SessionDirectory(url: root.appendingPathComponent(meta.id.uuidString, isDirectory: true))
        try directory.create()
        try directory.saveMeta(meta)
        if seconds > 0 {
            let recorder = try SegmentedRecorder(
                directory: directory.audioDirectoryURL, sampleRate: Fixture.sampleRate, segmentDuration: 1)
            try Signal.constant(0.25, count: Int(seconds * Fixture.sampleRate)).withUnsafeBufferPointer {
                try recorder.append($0)
            }
            try recorder.close()
        }
        return directory
    }

    @Test("只回報狀態還停在 recording 的場次，並算出救得回來的長度")
    func findsOnlyInterruptedSessions() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let interrupted = try makeSessionFolder(in: tmp.url, state: .recording, seconds: 2.5)
        _ = try makeSessionFolder(in: tmp.url, state: .finalizing, seconds: 1)
        _ = try makeSessionFolder(in: tmp.url, state: .complete, seconds: 1)

        let found = try SessionRecovery.findInterrupted(in: tmp.url)

        #expect(found.count == 1)
        #expect(found.first?.directory == interrupted)
        #expect(abs((found.first?.recordedDuration ?? -1) - 2.5) < 1e-9)
        #expect(found.first?.segmentCount == 3)
    }

    @Test("工作目錄裡不相干的檔案和資料夾會被忽略；目錄不存在時回傳空陣列")
    func ignoresUnrelatedItems() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        try FileManager.default.createDirectory(
            at: tmp.url.appendingPathComponent("not-a-session"), withIntermediateDirectories: true)
        try "hello".write(to: tmp.url.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        _ = try makeSessionFolder(in: tmp.url, state: .recording, seconds: 1)

        #expect(try SessionRecovery.findInterrupted(in: tmp.url).count == 1)
        #expect(try SessionRecovery.findInterrupted(in: tmp.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test("還沒錄到任何聲音就中斷的場次也找得到，長度是 0")
    func findsSessionsWithoutAudio() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        _ = try makeSessionFolder(in: tmp.url, state: .recording, seconds: 0)

        let found = try SessionRecovery.findInterrupted(in: tmp.url)

        #expect(found.count == 1)
        #expect(found.first?.recordedDuration == 0)
        #expect(found.first?.segmentCount == 0)
        if let session = found.first {
            let recovered = try SessionRecovery.recover(session)
            #expect(recovered.state == .finalizing)
            #expect(recovered.recovered)
            #expect(recovered.durationSeconds == 0)
        }
    }
}
