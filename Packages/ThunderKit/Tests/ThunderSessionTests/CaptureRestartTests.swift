import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 錄音中途收音被打斷之後接著錄同一場（DESIGN.md 2.3 節第 9 條、5.4 節、D26）：裝置不見、睡眠醒來、換了輸出裝置。
/// 用假的收音來源（樣本由測試寫進 RingBuffer），不碰 Core Audio。
@Suite("LiveRecording：收音中斷之後接著錄同一場", .timeLimit(.minutes(1)))
struct CaptureRestartTests {
    private func makeRecording(_ tmp: TemporaryDirectory, _ captures: FakeCaptures) -> LiveRecording {
        var options = LiveRecording.Options(
            source: .microphone(deviceUID: "usb-mic"), workingRoot: tmp.url.appendingPathComponent("Working"))
        options.engineName = "scripted"
        options.engineDrainTimeout = .milliseconds(300)
        return LiveRecording(options: options, engine: ScriptedEngine(.captions(every: 2)), makeCapture: captures.make) { _ in }
    }

    /// 等到錄下的長度至少有 `seconds` 秒。
    private func waitForAudio(_ recording: LiveRecording, _ seconds: Double) async -> Bool {
        await waitUntil(timeout: .seconds(3)) { recording.audioTime.seconds >= seconds - 0.000_1 }
    }

    private func interruptions(_ recording: LiveRecording) throws -> [AudioGap] {
        try JournalReader.read(recording.directory.journalURL).gaps.filter(\.isInterruption)
    }

    @Test("收音中途裝置不見了：換成新的來源接著錄同一場，前後的聲音都錄下來，日誌在中斷的位置記一筆中斷，錄音檔從那裡開新的分段")
    func restartsIntoTheSameSession() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 16_000, name: "USB 麥克風", uid: "usb-mic"), .init(rate: 16_000, name: "MacBook Pro 麥克風", uid: "built-in"),
        ])
        let recording = makeRecording(tmp, captures)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        try recording.resumeCapture(reason: .deviceLost)

        #expect(captures.made(0)?.isStopped == true)
        #expect(captures.made(1)?.isStarted == true)
        #expect(recording.sourceDescription == "MacBook Pro 麥克風")
        #expect(recording.captureDeviceUID == "built-in")
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        let segments = try RecordingFiles.segments(in: recording.directory.audioDirectoryURL)
        #expect(segments.map(\.frameCount) == [16_000, 16_000])
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.deviceLost])
        #expect(recorded.first?.from == AudioTime(seconds: 1))
    }

    @Test("新的來源取樣率不同（例如 AirPods 的麥克風是 24 kHz）：轉成這一場的取樣率再錄，錄音長度與音訊時間都對")
    func convertsToTheSessionRate() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 48_000, name: "USB 麥克風", uid: "usb-mic"), .init(rate: 24_000, name: "AirPods", uid: "airpods"),
        ])
        let recording = makeRecording(tmp, captures)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        try recording.resumeCapture(reason: .deviceLost)
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1.98))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.02, "錄到 \(meta.durationSeconds) 秒")
        let segments = try RecordingFiles.segments(in: recording.directory.audioDirectoryURL)
        #expect(segments.allSatisfy { $0.sampleRate == 48_000 })
    }

    @Test("電腦睡眠：睡著之前停止收音、把收到的聲音錄完；醒來之後接著錄，沒有錄到的時間從睡著算起")
    func sleepAndWake() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 16_000, name: "系統音訊", uid: "speakers"), .init(rate: 16_000, name: "系統音訊", uid: "speakers"),
        ])
        let recording = makeRecording(tmp, captures)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        recording.suspendCapture()
        #expect(captures.made(0)?.isStopped == true)
        #expect(recording.isCaptureInterrupted)
        try await Task.sleep(for: .milliseconds(200))
        try recording.resumeCapture(reason: .sleep)
        #expect(!recording.isCaptureInterrupted)
        captures.made(1)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        let recorded = try interruptions(recording)
        #expect(recorded.map(\.reason) == [.sleep])
        #expect((recorded.first?.lostSeconds ?? 0) >= 0.2)
        #expect((recorded.first?.lostSeconds ?? 99) < 10)
    }

    @Test("收音中斷期間按停止：照常結束，已經錄下的聲音都在")
    func stopWhileInterrupted() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([.init(rate: 16_000, name: "USB 麥克風", uid: "usb-mic")])
        let recording = makeRecording(tmp, captures)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        recording.suspendCapture()
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(meta.state == .finalizing)
        #expect(abs(meta.durationSeconds - 1) < 0.001)
        #expect(captures.made(0)?.isStopped == true)
    }

    @Test("重新開始收音失敗：丟出錯誤、場次照常；之後再試成功時只記一筆中斷，沒有錄到的時間從第一次中斷算起")
    func retriesAfterAFailedRestart() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 16_000, name: "USB 麥克風", uid: "usb-mic"), .init(rate: 16_000, name: "沒有裝置", uid: nil, fails: true),
            .init(rate: 16_000, name: "MacBook Pro 麥克風", uid: "built-in"),
        ])
        let recording = makeRecording(tmp, captures)
        try recording.start()
        captures.made(0)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 1))

        recording.suspendCapture()
        try await Task.sleep(for: .milliseconds(100))
        #expect(throws: FakeCaptureError.self) { try recording.resumeCapture(reason: .sleep) }
        #expect(recording.isCaptureInterrupted)
        try await Task.sleep(for: .milliseconds(100))
        try recording.resumeCapture(reason: .sleep)
        captures.made(2)?.feed(seconds: 1)
        #expect(await waitForAudio(recording, 2))
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }

        #expect(abs(meta.durationSeconds - 2) < 0.001)
        let recorded = try interruptions(recording)
        #expect(recorded.count == 1)
        #expect((recorded.first?.lostSeconds ?? 0) >= 0.2)
    }

    @Test("收音端的計數跨過重新開始：callback 次數與裝置的不連續次數都加總，不連續次數寫進 session.json")
    func countsAcrossRestarts() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let captures = FakeCaptures([
            .init(rate: 16_000, name: "USB 麥克風", uid: "usb-mic", callbacks: 100, discontinuities: 1),
            .init(rate: 16_000, name: "MacBook Pro 麥克風", uid: "built-in", callbacks: 50, discontinuities: 2),
        ])
        let recording = makeRecording(tmp, captures)
        try recording.start()

        try recording.resumeCapture(reason: .captureStalled)

        #expect(recording.captureCallbackCount == 150)
        let meta = try await withDeadline(.seconds(30)) { try await recording.stop() }
        #expect(meta.integrity.captureDiscontinuities == 3)
    }
}

struct FakeCaptureError: Error {}

/// 測試用的收音來源：樣本由測試寫進 RingBuffer（`feed`）。可以指定取樣率、說明、裝置、callback 與不連續的次數、開始時失敗。
final class FakeCapture: AudioCapturing, @unchecked Sendable {
    // @unchecked Sendable：會變的只有 `flags`（在 LockedValue 裡）與 `onEnded`（測試不用）。
    struct Plan {
        var rate: Double
        var name: String
        var uid: String?
        var fails = false
        var callbacks = 0
        var discontinuities = 0
    }

    let plan: Plan
    let ring: RingBuffer
    var onEnded: (@Sendable () -> Void)?
    private let flags = LockedValue((started: false, stopped: false))

    init(_ plan: Plan, ring: RingBuffer) {
        self.plan = plan
        self.ring = ring
    }

    var isStarted: Bool { flags.value.started }
    var isStopped: Bool { flags.value.stopped }

    func start() throws -> Double {
        if plan.fails { throw FakeCaptureError() }
        flags.withValue { $0.started = true }
        return plan.rate
    }

    func stop() { flags.withValue { $0.stopped = true } }
    var sourceDescription: String { plan.name }
    var notice: String? { nil }
    var deviceUID: String? { plan.uid }
    var callbackCount: Int { plan.callbacks }
    var discontinuityCount: Int { plan.discontinuities }
    var firstSampleUptimeNanoseconds: UInt64? { nil }

    /// 寫入 `seconds` 秒的固定音量訊號（RingBuffer 放得下約 20 秒）。
    func feed(seconds: Double) {
        _ = ring.write(Signal.constant(0.25, count: Int((seconds * plan.rate).rounded())))
    }
}

/// 依序交出事先準備好的收音來源（用完之後重複最後一個），記下交出了哪些。
final class FakeCaptures: Sendable {
    private let plans: [FakeCapture.Plan]
    private let handedOut = LockedValue<[FakeCapture]>([])

    init(_ plans: [FakeCapture.Plan]) {
        self.plans = plans
    }

    func make(_ source: CaptureSource, _ ring: RingBuffer) -> any AudioCapturing {
        handedOut.withValue { made in
            let capture = FakeCapture(plans[min(made.count, plans.count - 1)], ring: ring)
            made.append(capture)
            return capture
        }
    }

    /// 第 `index` 個交出的來源（從 0 開始）；還沒有交出那麼多時是 nil。
    func made(_ index: Int) -> FakeCapture? {
        let made = handedOut.value
        return index < made.count ? made[index] : nil
    }
}
