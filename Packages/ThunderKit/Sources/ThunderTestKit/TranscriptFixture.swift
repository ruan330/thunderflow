import Foundation

/// 實驗時錄下來的轉錄事件（`Benchmarks/fixtures/openai-transcribe/`），給測試重播。
///
/// 時間都是秒，從開始送音訊算起。錄的時候是以即時速度送音訊，所以它同時也是當下的音訊位置。
public struct TranscriptFixture: Sendable {
    /// 伺服器送來的一段增量文字。
    public struct Delta: Sendable, Equatable {
        public var time: TimeInterval
        public var text: String
        public var itemID: String
    }

    /// 音檔裡的一次停頓（由 `Tools/thunderbench/vad-plan.py` 算出）。
    public struct Pause: Sendable, Equatable {
        /// 最後一格語音結束的時間。
        public var speechEnd: TimeInterval
        /// 靜音滿門檻、偵測到停頓的時間。
        public var detectedAt: TimeInterval
    }

    /// 稿子裡的一句話，以及它在音檔裡的起訖。
    public struct Sentence: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
    }

    public struct NotFound: Error, CustomStringConvertible {
        public let path: String
        public let startedFrom: String
        public var description: String { "從 \(startedFrom) 往上找不到 \(path)" }
    }

    public static let relativeDirectory = "Benchmarks/fixtures/openai-transcribe"

    public var deltas: [Delta]
    public var pauses: [Pause]
    public var sentences: [Sentence]

    /// 所有增量文字依序接起來。
    public var text: String { deltas.map(\.text).joined() }

    /// - Parameters:
    ///   - events: 事件檔的名稱（不含 `.jsonl`），例如 `keynote-single-turn`。
    ///   - audio: 音檔的名稱，用來載入它的停頓與句子（`<audio>.pauses.json`）。不給就沒有停頓資料。
    public static func load(events: String, audio: String? = nil, near sourceFile: String = #filePath) throws -> TranscriptFixture {
        let directory = try locate(near: sourceFile)
        var fixture = TranscriptFixture(deltas: [], pauses: [], sentences: [])

        let lines = try Data(contentsOf: directory.appendingPathComponent("\(events).jsonl"))
            .split(separator: UInt8(ascii: "\n"))
        for line in lines {
            guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = record["event"] as? [String: Any],
                event["type"] as? String == "conversation.item.input_audio_transcription.delta",
                let milliseconds = record["rx_ms"] as? Double
            else { continue }
            fixture.deltas.append(
                Delta(
                    time: milliseconds / 1000, text: event["delta"] as? String ?? "",
                    itemID: event["item_id"] as? String ?? ""))
        }

        if let audio {
            struct PauseFile: Decodable {
                struct Pause: Decodable {
                    var speech_end_ms: Double
                    var detected_ms: Double
                }
                struct Sentence: Decodable {
                    var start_ms: Double
                    var end_ms: Double
                    var text: String
                }
                var pauses: [Pause]
                var sentences: [Sentence]
            }
            let file = try JSONDecoder().decode(
                PauseFile.self, from: Data(contentsOf: directory.appendingPathComponent("\(audio).pauses.json")))
            fixture.pauses = file.pauses.map { Pause(speechEnd: $0.speech_end_ms / 1000, detectedAt: $0.detected_ms / 1000) }
            fixture.sentences = file.sentences.map { Sentence(start: $0.start_ms / 1000, end: $0.end_ms / 1000, text: $0.text) }
        }
        return fixture
    }

    private static func locate(near sourceFile: String) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relativeDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw NotFound(path: relativeDirectory, startedFrom: sourceFile)
    }
}
