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

private func english(_ text: String, _ kind: TextKind, segment: Int?) -> CaptionEvent {
    .source(CaptionText(text: text, kind: kind, at: AudioTime(seconds: 1), segment: segment))
}

/// 即時逐字稿裡兩行說明之後的每一行。
private func rawLines(_ directory: SessionDirectory) -> [String] {
    guard let text = try? String(contentsOf: directory.liveTranscriptURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("# ") }
}

/// 同上，去掉每一行前面的時刻（「[10:30:12] 」）。
private func spokenLines(_ directory: SessionDirectory) -> [String] {
    rawLines(directory).map { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}

@Suite("錄音中的即時逐字稿（live-transcript.txt，D34）", .timeLimit(.minutes(1)))
struct LiveTranscriptRecordingTests {
    @Test("建立場次後，資料夾裡立刻有即時逐字稿，開頭是兩行說明（標題、開始的時間）")
    func createdWithSession() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ListEngine(events: []))
        let text = try String(contentsOf: directory.liveTranscriptURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("# ThunderFlow 即時逐字稿｜測試場次｜") == true)
        #expect(lines.first?.hasSuffix(" 開始") == true)
        #expect(lines.last == "# 英文由語音自動辨識，可能有錯字；⚑ 是使用者標記的重點")
        try await session.finish()
    }

    @Test("只寫一段確定的英文：增量、中文定稿、暫定譯文都不寫；同一段再確定一次時以最後一次為準")
    func onlyFinalEnglish() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ListEngine(events: [
            english("Hel", .delta, segment: 0),
            english("lo there", .delta, segment: 0),
            .provisional(CaptionText(text: "你好", kind: .delta, at: AudioTime(seconds: 1), segment: 0)),
            english("Hello there", .segmentEnd, segment: 0),
            .translation(CaptionText(text: "你好。", kind: .segmentEnd, at: AudioTime(seconds: 2), segment: 0)),
            english("Hello there.", .segmentEnd, segment: 0),
            english("Next one.", .segmentEnd, segment: 1),
        ])
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)
        session.start()
        #expect(await waitUntil { spokenLines(directory).last == "Next one." })
        try await session.finish()
        #expect(spokenLines(directory) == ["Hello there.", "Next one."])
        #expect(rawLines(directory).allSatisfy { $0.wholeMatch(of: /\[\d\d:\d\d:\d\d\] .+/) != nil })
    }

    @Test("引擎回報的缺口寫成一行")
    func engineGap() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let gap = AudioGap(from: AudioTime(seconds: 10), to: AudioTime(seconds: 22), reason: .network)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ListEngine(events: [.gap(gap)]))
        session.start()
        #expect(await waitUntil { !spokenLines(directory).isEmpty })
        try await session.finish()
        #expect(spokenLines(directory) == ["〔約 12 秒沒有字幕：網路中斷〕"])
    }

    @Test("標記、暫停、繼續、錄音中斷依序各寫一行；狀態沒變的暫停不重寫")
    func controls() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ListEngine(events: []))
        session.start()
        session.mark()
        session.pause()
        session.pause()
        session.resume()
        session.recordInterruption(reason: .sleep, lostSeconds: 845.25)
        try await session.finish()
        #expect(
            spokenLines(directory) == [
                "⚑ 標記", "—— 暫停 ——", "—— 繼續 ——", "〔錄音中斷：電腦睡眠，約 14 分鐘沒有錄到〕",
            ])
    }

    @Test("錄音結束（還沒做結束處理）時，即時逐字稿還在，結束之後的操作不再寫進去")
    func keptUntilFinalized() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ListEngine(events: []))
        session.start()
        session.mark()
        try await session.finish()
        session.mark()
        #expect(fileExists(directory.liveTranscriptURL))
        #expect(spokenLines(directory) == ["⚑ 標記"])
    }
}

@Suite("結束處理與即時逐字稿（D34）", .timeLimit(.minutes(1)))
struct LiveTranscriptFinalizationTests {
    @Test("做好逐字稿之後刪除即時逐字稿：搬進 Library 的資料夾和以前完全一樣")
    func removedAfterTranscript() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let working = tmp.url.appendingPathComponent("Working", isDirectory: true)
        let library = tmp.url.appendingPathComponent("Library", isDirectory: true)
        let directory = try Finished.makeSession(in: working)
        try "# ThunderFlow 即時逐字稿\n[10:30:12] Hello\n".write(
            to: directory.liveTranscriptURL, atomically: true, encoding: .utf8)
        let published = try await SessionFinalizer(options: FinalizationOptions(libraryRoot: library)).finalize(directory)
        #expect(!fileExists(published.liveTranscriptURL))
        try Finished.expectPublished(published, in: library)
    }
}
