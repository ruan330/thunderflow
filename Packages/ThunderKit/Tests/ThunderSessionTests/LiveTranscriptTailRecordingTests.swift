import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 一開始就照順序送出一串事件的引擎；送完之後消化音訊，音訊結束就收尾。
private struct ListEngine: LiveCaptionEngine {
    let events: [CaptionEvent]

    func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent> {
        let events = events
        return AsyncStream { continuation in
            let task = Task {
                for event in events { continuation.yield(event) }
                for await _ in audio {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func english(_ text: String, _ kind: TextKind, segment: Int) -> CaptionEvent {
    .source(CaptionText(text: text, kind: kind, at: AudioTime(seconds: 1), segment: segment))
}

private func spokenLines(_ directory: SessionDirectory) -> [String] {
    guard let text = try? String(contentsOf: directory.liveTranscriptURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("# ") }.map { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}

@Suite("錄音中的即時逐字稿：真的引擎的事件順序（D34）", .timeLimit(.minutes(1)))
struct LiveTranscriptTailRecordingTests {
    @Test("晚到的尾巴先以下一段的增量送出、再併回上一段（實測的順序）：寫出的是補完的那一句，而且不用等計時")
    func realEngineOrder() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ListEngine(events: [
            english(" Good morning everyone, and welcome to the", .delta, segment: 0),
            english("Good morning everyone, and welcome to the", .segmentEnd, segment: 0),
            english(" conference", .delta, segment: 1),
            english(".", .delta, segment: 1),
            english("Good morning everyone, and welcome to the conference.", .segmentEnd, segment: 0),
            english(" Today", .delta, segment: 1),
            english(" I", .delta, segment: 1),
        ])
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)
        session.start()
        #expect(
            await waitUntil(timeout: .seconds(1)) {
                spokenLines(directory) == ["Good morning everyone, and welcome to the conference."]
            })
        try await session.finish()
        #expect(spokenLines(directory) == ["Good morning everyone, and welcome to the conference."])
    }
}
