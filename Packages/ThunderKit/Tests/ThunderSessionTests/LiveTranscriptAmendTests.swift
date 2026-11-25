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

/// 即時逐字稿裡兩行說明之後的每一行，去掉前面的時刻。
private func spokenLines(_ directory: SessionDirectory) -> [String] {
    guard let text = try? String(contentsOf: directory.liveTranscriptURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("# ") }.map { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}

@Suite("錄音中的即時逐字稿：一段補上最後的字之後才寫（D34）", .timeLimit(.minutes(1)))
struct LiveTranscriptAmendTests {
    @Test("真的引擎常在一段確定後再補上最後的字：下一段開始說時就寫出補完的那一句，不用等")
    func writesCompletedSegmentWhenNextStarts() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ListEngine(events: [
            english("Good morning everyone, and welcome to the", .segmentEnd, segment: 0),
            english("Good morning everyone, and welcome to the conference.", .segmentEnd, segment: 0),
            english("Today", .delta, segment: 1),
        ])
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)
        session.start()
        // 只等 1 秒：比「一段時間沒有變化」短，寫出來是因為下一段開始說了
        #expect(
            await waitUntil(timeout: .seconds(1)) {
                spokenLines(directory) == ["Good morning everyone, and welcome to the conference."]
            })
        try await session.finish()
        #expect(spokenLines(directory) == ["Good morning everyone, and welcome to the conference."])
    }
}
