import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

@Suite("LiveRecording：收音、錄音與引擎組在一起")
struct LiveRecordingTests {
    /// 用錄音元件寫出一個音檔，當成收音的來源。
    private func makeAudioFile(in directory: URL, seconds: Double) throws -> URL {
        let recorder = try SegmentedRecorder(directory: directory, sampleRate: 16_000)
        let samples = Signal.sine(frequency: 440, sampleRate: 16_000, duration: seconds)
        try samples.withUnsafeBufferPointer { try recorder.append($0) }
        try recorder.close()
        let segments = try RecordingFiles.segments(in: directory)
        return try #require(segments.first).url
    }

    @Test("音檔來源加腳本引擎：聲音完整錄下，字幕寫進日誌也送到畫面，場次資訊與完整性計數寫進 session.json")
    func recordsFromFile() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let file = try makeAudioFile(in: tmp.url.appendingPathComponent("source"), seconds: 1.2)

        let events = LockedValue<[CaptionEvent]>([])
        let ended = LockedValue(false)
        var options = LiveRecording.Options(source: .file(file), workingRoot: tmp.url.appendingPathComponent("Working"))
        options.title = "測試場次"
        options.event = "re:Invent"
        options.speaker = "Jane"
        options.keywords = ["AgentCore"]
        options.engineName = "scripted"
        let recording = LiveRecording(options: options, engine: ScriptedEngine(.segments(every: 0.4))) { event in
            events.withValue { $0.append(event) }
        }
        recording.onSourceEnded = { ended.withValue { $0 = true } }

        try recording.start()
        let finished = await waitUntil(timeout: .seconds(5), { ended.value })
        #expect(finished, "音檔播完要通知")
        #expect(recording.captureCallbackCount == 0, "音檔來源不經過裝置的 callback")
        let meta = try await recording.stop()

        #expect(meta.state == .finalizing)
        #expect(abs(meta.durationSeconds - 1.2) < 0.001)
        #expect(meta.title == "測試場次")
        #expect(meta.event == "re:Invent")
        #expect(meta.speaker == "Jane")
        #expect(meta.keywords == ["AgentCore"])
        #expect(meta.engine == "scripted")
        #expect(meta.source.contains("000.caf"))
        #expect(meta.integrity.isRecordingComplete)
        #expect(meta.id == recording.id)
        let saved = try recording.directory.loadMeta()
        #expect(saved == meta)

        let segments = try RecordingFiles.segments(in: recording.directory.audioDirectoryURL)
        #expect(RecordingFiles.totalFrames(of: segments) == 19_200, "樣本一個不少")
        let journal = try JournalReader.read(recording.directory.journalURL)
        let journaled = journal.entries.filter { if case .translation = $0 { true } else { false } }
        #expect(journaled.count == 3)
        let seen = events.value
        #expect(seen.filter { if case .translation = $0 { true } else { false } }.count == 3)
        #expect(seen.contains { if case .provisional = $0 { true } else { false } }, "畫面收得到不進日誌的暫定譯文")
    }

    @Test("來源打不開：開始時丟出錯誤，不留下場次資料夾")
    func failsToStart() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let working = tmp.url.appendingPathComponent("Working")
        let options = LiveRecording.Options(source: .file(tmp.url.appendingPathComponent("missing.wav")), workingRoot: working)
        let recording = LiveRecording(options: options, engine: ScriptedEngine(.segments(every: 1))) { _ in }
        #expect(throws: AudioCaptureError.self) { try recording.start() }
        #expect(!FileManager.default.fileExists(atPath: recording.directory.url.path))
    }
}
