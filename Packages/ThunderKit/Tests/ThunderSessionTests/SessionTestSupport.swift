import Foundation
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

enum Fixture {
    /// 場次測試預設用 16 kHz：行為與取樣率無關，資料量小、跑得快。
    static let sampleRate = 16_000.0
    static let startedAt = Date(timeIntervalSince1970: 1_796_000_000)

    static func config(_ configure: (inout SessionConfig) -> Void = { _ in }) -> SessionConfig {
        var config = SessionConfig(sampleRate: sampleRate)
        config.title = "測試場次"
        config.startedAt = startedAt
        config.source = "合成音訊"
        config.engineName = "scripted"
        config.engineDrainTimeout = .milliseconds(300)
        configure(&config)
        return config
    }

    /// 在 `root` 底下建立一個新的場次（資料夾以場次 id 命名）。
    static func makeSession(
        in root: URL,
        engine: any LiveCaptionEngine,
        configure: (inout SessionConfig) -> Void = { _ in }
    ) throws -> (session: RecordingSession, directory: SessionDirectory) {
        let config = config(configure)
        let directory = SessionDirectory(url: root.appendingPathComponent(config.id.uuidString, isDirectory: true))
        return (try RecordingSession(config: config, directory: directory, engine: engine), directory)
    }
}

struct LockstepTimeout: Error, CustomStringConvertible {
    var description: String { "引擎超過 5 秒沒有跟上送入的音訊" }
}

/// 以 20 ms 一包、不等待的方式送入 `seconds` 秒的固定音量訊號。回傳送入的樣本數。
///
/// 速度遠超過即時，引擎通常來不及消化，等待區會溢位。用於「引擎故障時錄音不受影響」這類測試。
@discardableResult
func feed(
    _ session: RecordingSession,
    seconds: Double,
    level: Float = 0.25,
    sampleRate: Double = Fixture.sampleRate
) throws -> Int {
    let chunk = Signal.constant(level, count: Int(sampleRate / 50))
    let rounds = Int((seconds * 50).rounded())
    for _ in 0..<rounds {
        try chunk.withUnsafeBufferPointer { try session.process($0) }
    }
    return rounds * chunk.count
}

/// 一秒一秒地送，每送一秒就等引擎跟上（最多落後 0.5 秒）。回傳送入的樣本數。
///
/// 這樣等待區不會溢位，字幕的內容與數量完全確定。用於要核對字幕的測試。
/// 等引擎的時候把執行緒讓出來，引擎才排得進來（見 `waitUntil` 的說明）。
@discardableResult
func feedInLockstep(
    _ session: RecordingSession,
    engine: ScriptedEngine,
    seconds: Int,
    level: Float = 0.25,
    sampleRate: Double = Fixture.sampleRate
) async throws -> Int {
    var fed = 0
    for _ in 0..<seconds {
        fed += try feed(session, seconds: 1, level: level, sampleRate: sampleRate)
        let target = session.audioTime.seconds - 0.5
        guard await waitUntil(timeout: .seconds(5), { engine.receivedDuration >= target }) else { throw LockstepTimeout() }
    }
    return fed
}

/// 相鄰兩包之間最大的時間縫隙（秒）。一包接一包的話應該是 0。
func largestSeam(in chunks: [ScriptedEngine.ReceivedChunk]) -> TimeInterval {
    zip(chunks, chunks.dropFirst()).reduce(0) { max($0, abs($1.1.startTime - $1.0.endTime)) }
}

func recordedSegments(_ directory: SessionDirectory) throws -> [RecordingSegment] {
    try RecordingFiles.segments(in: directory.audioDirectoryURL)
}

func recordedFrames(_ directory: SessionDirectory) throws -> Int64 {
    RecordingFiles.totalFrames(of: try recordedSegments(directory))
}

/// 讀出整場錄音的全部樣本。
func recordedSamples(_ directory: SessionDirectory) throws -> [Float] {
    try recordedSegments(directory).flatMap { try RecordingFiles.readSamples(of: $0) }
}

extension JournalContents {
    var sources: [CaptionText] {
        entries.compactMap { entry -> CaptionText? in
            if case .source(let text) = entry { text } else { nil }
        }
    }

    var translations: [CaptionText] {
        entries.compactMap { entry -> CaptionText? in
            if case .translation(let text) = entry { text } else { nil }
        }
    }

    var gaps: [AudioGap] {
        entries.compactMap { entry -> AudioGap? in
            if case .gap(let gap) = entry { gap } else { nil }
        }
    }

    var markers: [AudioTime] {
        entries.compactMap { entry -> AudioTime? in
            if case .marker(let time) = entry { time } else { nil }
        }
    }

    /// 日誌裡出現過的最晚音訊時間。
    var latestTime: AudioTime {
        entries.reduce(AudioTime.zero) { latest, entry in
            switch entry {
            case .source(let text), .translation(let text): max(latest, text.at)
            case .gap(let gap): max(latest, gap.to)
            case .marker(let time), .paused(let time), .resumed(let time): max(latest, time)
            }
        }
    }
}
