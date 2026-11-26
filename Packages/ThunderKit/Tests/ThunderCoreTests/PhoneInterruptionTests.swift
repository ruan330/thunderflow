import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// iPhone 被來電、Siri 或別的 App 用了麥克風而停止收音（DESIGN.md 5.10 節，D36）：打斷結束後接著錄同一場，
/// 日誌記一筆中斷（`why` 是 `interrupted`），逐字稿與即時逐字稿標出來。只增不改：`schemaVersion` 維持 1。
@Suite("iPhone 被打斷：日誌與逐字稿的標示（D36）")
struct PhoneInterruptionTests {
    @Test("日誌記一筆 interrupted 的中斷（長度 0、沒有錄到多久），讀回來一樣，算是錄音中斷")
    func journalRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let gap = AudioGap.interruption(at: AudioTime(seconds: 300), lostSeconds: 42.5, reason: .interrupted)
        let writer = try JournalWriter(url: url)
        try writer.append(.gap(gap))
        writer.close()

        #expect(
            try String(contentsOf: url, encoding: .utf8)
                == #"{"k":"gap","from":300,"to":300,"why":"interrupted","lost":42.5}"# + "\n")
        #expect(try JournalReader.read(url).entries == [.gap(gap)])
        #expect(gap.isInterruption)
    }

    @Test("逐字稿的標示：「〔錄音中斷：來電或其他 App 用了麥克風，約 N 秒沒有錄到〕」，段落在那裡結束")
    func label() {
        #expect(
            TranscriptInterruption(at: 300, reason: .interrupted, lostSeconds: 42.5).label
                == "〔錄音中斷：來電或其他 App 用了麥克風，約 43 秒沒有錄到〕")
        let entries: [JournalEntry] = [
            .source(CaptionText(text: "Before the call.", kind: .segmentEnd, at: AudioTime(seconds: 290), segment: 0)),
            .gap(.interruption(at: AudioTime(seconds: 300), lostSeconds: 42.5, reason: .interrupted)),
            .source(CaptionText(text: "After the call.", kind: .segmentEnd, at: AudioTime(seconds: 305), segment: 1)),
        ]
        let blocks = TranscriptBlocks.build(from: entries).blocks
        #expect(blocks.count == 2)
        #expect(blocks.last?.interruptionsBefore.map(\.reason) == [.interrupted])
    }

    @Test("即時逐字稿也寫出這一行")
    func liveTranscriptLine() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("live-transcript.txt")
        let start = ISO8601DateFormatter().date(from: "2026-12-01T10:30:00Z")!
        let writer = try LiveTranscriptWriter(
            url: url, title: "Keynote", startedAt: start, timeZone: TimeZone(identifier: "UTC")!,
            settleDelay: .seconds(60), clock: { start.addingTimeInterval(300) })

        writer.append(.gap(.interruption(at: AudioTime(seconds: 300), lostSeconds: 42.5, reason: .interrupted)))
        writer.close()

        let body = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).dropFirst(2)
        #expect(Array(body) == ["[10:35:00] 〔錄音中斷：來電或其他 App 用了麥克風，約 43 秒沒有錄到〕"])
    }
}
