import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 錄音中或暫停中換音訊來源，接著錄同一場（D35）：先停掉原本的收音、把收到的聲音錄完，再開始新選的來源。
/// 用假的收音來源（`FakeCaptures`，在 CaptureRestartTests.swift），不碰 Core Audio。
@Suite("LiveRecording：錄音中換音訊來源，接著錄同一場（D35）", .timeLimit(.minutes(1)))
struct SourceSwitchTests {
    /// 每次建立收音來源時要的是哪一種來源。
    private final class Requests: Sendable {
        let sources = LockedValue<[CaptureSource]>([])
    }

    private func makeRecording(
        _ tmp: TemporaryDirectory, _ captures: FakeCaptures, _ requests: Requests, source: CaptureSource
    ) -> LiveRecording {
        var options = LiveRecording.Options(source: source, workingRoot: tmp.url.appendingPathComponent("Working"))
        options.engineName = "scripted"
        options.engineDrainTimeout = .milliseconds(300)
        return LiveRecording(
            options: options, engine: ScriptedEngine(.captions(every: 2)),
            makeCapture: { source, ring in
                requests.sources.withValue { $0.append(source) }
                return captures.make(source, ring)
            }
        ) { _ in }
    }

    private func waitForAudio(_ recording: LiveRecording, _ seconds: Double) async -> Bool {
        await waitUntil(timeout: .seconds(3)) { recording.audioTime.seconds >= seconds - 0.000_1 }
    }

    private func interruptions(_ recording: LiveRecording) throws -> [AudioGap] {
        try JournalReader.read(recording.directory.journalURL).gaps.filter(\.isInterruption)
    }

    private let speakers = FakeCapture.Plan(rate: 16_000, name: "系統音訊", uid: "speakers")
    private let builtIn = FakeCapture.Plan(rate: 16_000, name: "MacBook Pro 麥克風", uid: "built-in")
    private let usb = FakeCapture.Plan(rate: 16_000, name: "USB 麥克風", uid: "usb-mic")

    @Test("錄音中換來源：停掉原本的、開始新選的，同一場接著錄；日誌在換的位置記一筆並寫出新來源，session.json 列出用過的兩個來源")
    func switchesWhileRecording() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([speakers, builtIn])
        let requests = Requests()
        let recording = makeRecording(tmp, captures, requests, source: .systemAudio)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        let lost = try recording.switchSource(to: .microphone(deviceUID: "built-in"))

        #expect(captures.made(0)?.isStopped == true)
        #expect(captures.made(1)?.isStarted == true)
        #expect(requests.sources.value == [.systemAudio, .microphone(deviceUID: "built-in")])
        #expect(recording.source == .microphone(deviceUID: "built-in"))
        #expect(recording.sourceDescription == "MacBook Pro 麥克風")
        #expect(!recording.isCaptureInterrupted)
        #expect(lost < 1)
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        #expect(meta.source == "系統音訊、MacBook Pro 麥克風")
        #expect(try recording.directory.loadMeta().source == "系統音訊、MacBook Pro 麥克風")
        let segments = try RecordingFiles.segments(in: recording.directory.audioDirectoryURL)
        #expect(segments.map(\.frameCount) == [16_000, 16_000])
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.sourceChanged])
        #expect(recorded.first?.from == AudioTime(seconds: 1))
        #expect(recorded.first?.source == "MacBook Pro 麥克風")
        let live = try String(contentsOf: recording.directory.liveTranscriptURL, encoding: .utf8)
        #expect(live.contains("〔音訊來源：MacBook Pro 麥克風〕"))
    }

    @Test("新來源的取樣率不同：轉成這一場的取樣率再錄，錄音長度與音訊時間都對")
    func convertsToTheSessionRate() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 48_000, name: "系統音訊", uid: "speakers"), .init(rate: 24_000, name: "AirPods", uid: "airpods"),
        ])
        let recording = makeRecording(tmp, captures, Requests(), source: .systemAudio)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        try recording.switchSource(to: .microphone(deviceUID: "airpods"))
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1.98))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.02, "錄到 \(meta.durationSeconds) 秒")
        let segments = try RecordingFiles.segments(in: recording.directory.audioDirectoryURL)
        #expect(segments.allSatisfy { $0.sampleRate == 48_000 })
    }

    @Test("換過來源之後收音又被打斷（例如裝置不見）：重新開始時用的是新選的來源，不是開始時的")
    func laterRestartsUseTheNewSource() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([speakers, builtIn, builtIn])
        let requests = Requests()
        let recording = makeRecording(tmp, captures, requests, source: .systemAudio)
        try recording.start()

        try recording.switchSource(to: .microphone(deviceUID: "built-in"))
        try recording.resumeCapture(reason: .deviceLost)

        #expect(
            requests.sources.value == [
                .systemAudio, .microphone(deviceUID: "built-in"), .microphone(deviceUID: "built-in"),
            ])
        try await withDeadline(.seconds(30)) { try await recording.stop() }
    }

    @Test("新的來源開始不了（例如還沒有系統音訊的權限）：丟出它的錯誤，用原本的來源接著錄同一場，來源與 session.json 都不變")
    func failedSwitchKeepsTheOldSource() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let failing = FakeCapture.Plan(rate: 16_000, name: "系統音訊", uid: nil, fails: true)
        let captures = FakeCaptures([usb, failing, usb])
        let requests = Requests()
        let recording = makeRecording(tmp, captures, requests, source: .microphone(deviceUID: "usb-mic"))
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        #expect(throws: FakeCaptureError.self) { try recording.switchSource(to: .systemAudio) }

        #expect(
            requests.sources.value == [
                .microphone(deviceUID: "usb-mic"), .systemAudio, .microphone(deviceUID: "usb-mic"),
            ])
        #expect(recording.source == .microphone(deviceUID: "usb-mic"))
        #expect(recording.sourceDescription == "USB 麥克風")
        #expect(!recording.isCaptureInterrupted)
        #expect(captures.made(2)?.isStarted == true)
        captures.made(2)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        #expect(meta.source == "USB 麥克風")
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.sourceChanged])
        #expect(recorded.first?.source == "USB 麥克風")
    }

    @Test("新的來源開始不了，原本的也開始不了：丟出新來源的錯誤、維持中斷中；之後再換成功時只記一筆，已經錄下的都在")
    func bothFailThenRetry() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            usb, .init(rate: 16_000, name: "系統音訊", uid: nil, fails: true),
            .init(rate: 16_000, name: "USB 麥克風", uid: "usb-mic", fails: true), builtIn,
        ])
        let recording = makeRecording(tmp, captures, Requests(), source: .microphone(deviceUID: "usb-mic"))
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        #expect(throws: FakeCaptureError.self) { try recording.switchSource(to: .systemAudio) }
        #expect(recording.isCaptureInterrupted)
        #expect(recording.source == .microphone(deviceUID: "usb-mic"))

        try recording.switchSource(to: .microphone(deviceUID: "built-in"))
        #expect(!recording.isCaptureInterrupted)
        captures.made(3)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        #expect(meta.source == "USB 麥克風、MacBook Pro 麥克風")
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.sourceChanged])
        #expect(recorded.first?.source == "MacBook Pro 麥克風")
    }

    @Test("暫停中換來源：換好之後按繼續，暫停前後的聲音都錄下來；日誌的順序是暫停、換來源、繼續")
    func switchWhilePaused() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([speakers, builtIn])
        let recording = makeRecording(tmp, captures, Requests(), source: .systemAudio)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        recording.pause()
        try recording.switchSource(to: .microphone(deviceUID: "built-in"))
        #expect(recording.isPaused)
        recording.resume()
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        let order = try JournalReader.read(recording.directory.journalURL).entries.compactMap { entry -> String? in
            switch entry {
            case .paused: "暫停"
            case .resumed: "繼續"
            case .gap(let gap) where gap.reason == .sourceChanged: "換來源"
            default: nil
            }
        }
        #expect(order == ["暫停", "換來源", "繼續"])
    }

    @Test("選的就是正在用的來源：什麼都不做，不重新開始收音，日誌也不記")
    func sameSourceDoesNothing() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([speakers, speakers])
        let recording = makeRecording(tmp, captures, Requests(), source: .systemAudio)
        try recording.start()

        let lost = try recording.switchSource(to: .systemAudio)

        #expect(lost == 0)
        #expect(captures.made(1) == nil)
        #expect(captures.made(0)?.isStopped == false)
        try await withDeadline(.seconds(30)) { try await recording.stop() }
        #expect(try interruptions(recording).isEmpty)
    }

    @Test("收音中斷中（例如找不到裝置）換來源：用新選的來源接著錄，沒有錄到的時間從中斷算起")
    func switchResumesAnInterruptedCapture() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([usb, speakers])
        let recording = makeRecording(tmp, captures, Requests(), source: .microphone(deviceUID: "usb-mic"))
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        recording.suspendCapture()
        try await Task.sleep(for: .milliseconds(200))
        let lost = try recording.switchSource(to: .systemAudio)

        #expect(!recording.isCaptureInterrupted)
        #expect(lost >= 0.2)
        try await withDeadline(.seconds(30)) { try await recording.stop() }
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.sourceChanged])
        #expect((recorded.first?.lostSeconds ?? 0) >= 0.2)
    }

    @Test("收音中斷中選回原本的來源：也會重新開始收音，不是什麼都不做")
    func sameSourceWhileInterruptedRestarts() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([usb, usb])
        let recording = makeRecording(tmp, captures, Requests(), source: .microphone(deviceUID: "usb-mic"))
        try recording.start()

        recording.suspendCapture()
        try recording.switchSource(to: .microphone(deviceUID: "usb-mic"))

        #expect(!recording.isCaptureInterrupted)
        #expect(captures.made(1)?.isStarted == true)
        try await withDeadline(.seconds(30)) { try await recording.stop() }
    }

    @Test("停止之後換來源：丟出 alreadyFinished，不建立新的來源")
    func noSwitchAfterStop() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([speakers, builtIn])
        let recording = makeRecording(tmp, captures, Requests(), source: .systemAudio)
        try recording.start()
        try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(throws: RecordingSessionError.alreadyFinished) {
            try recording.switchSource(to: .microphone(deviceUID: "built-in"))
        }
        #expect(captures.made(1) == nil)
    }
}
