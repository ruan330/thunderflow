import Foundation
import Synchronization
import Testing
import ThunderCore
import ThunderTestKit

/// 每讀一次就往後走一格的假時鐘（走到最後一格就停在那裡）。
private final class SteppingClock: Sendable {
    private let times: Mutex<[Date]>

    init(_ times: [Date]) { self.times = Mutex(times) }

    func now() -> Date { times.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// 真的引擎常在一段確定之後 0.2–0.8 秒再確定一次、補上最後一兩個字（2026-11-25 實測 7 段裡 6 段），
/// 所以一段要等它真的確定了才寫：下一段開始有字，或一段時間沒有變化。
@Suite("即時逐字稿：一段等真的確定了才寫（D34）", .timeLimit(.minutes(1)))
struct LiveTranscriptSettleTests {
    /// `settle` 預設很長：只有下一段開始、或關檔時才會寫出去。
    private func makeWriter(
        in tmp: TemporaryDirectory, times: [String] = ["2026-12-01T10:30:12Z"], settle: Duration = .seconds(60)
    ) throws -> (LiveTranscriptWriter, URL) {
        let url = tmp.url.appendingPathComponent("live-transcript.txt")
        let clock = SteppingClock(times.map(at))
        let writer = try LiveTranscriptWriter(
            url: url, title: "GameDay", startedAt: at("2026-12-01T10:30:00Z"), timeZone: TimeZone(identifier: "UTC")!,
            settleDelay: settle, clock: { clock.now() })
        return (writer, url)
    }

    /// 兩行說明之後的內容。
    private func body(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").map(String.init).dropFirst(2))
    }

    @Test("一段確定之後先不寫；下一段開始有字時，前一段才寫出去（之後不會再補前一段）")
    func waitsForNextSegment() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Good morning everyone, and welcome to the", segment: 0))
        #expect(body(url).isEmpty)
        writer.append(.speech("Good morning everyone, and welcome to the conference.", segment: 0))
        #expect(body(url).isEmpty)
        writer.append(.speaking(segment: 1))
        #expect(body(url) == ["[10:30:12] Good morning everyone, and welcome to the conference."])
        writer.close()
    }

    @Test("講者停下來時，最後一段在一小段時間沒有變化之後寫出去，不會一直等下一段")
    func settlesWhenQuiet() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, settle: .milliseconds(50))
        writer.append(.speech("That's all for the briefing.", segment: 5))
        #expect(await waitUntil { body(url) == ["[10:30:12] That's all for the briefing."] })
        writer.close()
        #expect(body(url) == ["[10:30:12] That's all for the briefing."])
    }

    @Test("補上字的時候重新計時：最後一次確定之後滿一段時間才寫")
    func amendmentRestartsTheWait() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, settle: .milliseconds(300))
        writer.append(.speech("Up to eight", segment: 4))
        try await Task.sleep(for: .milliseconds(200))
        writer.append(.speech("Up to eight hours.", segment: 4))
        try await Task.sleep(for: .milliseconds(200))
        #expect(body(url).isEmpty)
        #expect(await waitUntil { body(url) == ["[10:30:12] Up to eight hours."] })
        writer.close()
    }

    @Test("時間是這一段第一次確定的時刻，不是補上字的時刻")
    func keepsFirstTime() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, times: ["2026-12-01T10:30:12Z", "2026-12-01T10:30:13Z"])
        writer.append(.speech("On Amazon", segment: 0))
        writer.append(.speech("On Amazon Bedrock.", segment: 0))
        writer.close()
        #expect(body(url) == ["[10:30:12] On Amazon Bedrock."])
    }

    @Test("一段還沒寫出去時按了標記：標記跟在那一段後面，照發生的順序，時間是按下的時刻")
    func markerWaitsBehindPendingSpeech() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, times: ["2026-12-01T10:30:12Z", "2026-12-01T10:30:14Z"])
        writer.append(.speech("Scoring changes at noon.", segment: 0))
        writer.append(.marker)
        #expect(body(url).isEmpty)
        writer.append(.speaking(segment: 1))
        #expect(body(url) == ["[10:30:12] Scoring changes at noon.", "[10:30:14] ⚑ 標記"])
        writer.close()
    }

    @Test("沒有還沒寫的段時，標記、暫停、繼續直接寫")
    func controlsWithoutPendingSpeech() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.marker)
        writer.append(.paused)
        #expect(body(url) == ["[10:30:12] ⚑ 標記", "[10:30:12] —— 暫停 ——"])
        writer.close()
    }

    @Test("已經寫出去的段再確定一次（太晚了）不重寫；同一段的增量不會讓它提早寫出去")
    func lateAmendmentIgnored() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("First.", segment: 0))
        writer.append(.speaking(segment: 0))
        #expect(body(url).isEmpty)
        writer.append(.speaking(segment: 1))
        writer.append(.speech("First, really.", segment: 0))
        writer.close()
        #expect(body(url) == ["[10:30:12] First."])
    }

    @Test("關檔時把還沒寫出去的寫出去")
    func closeFlushes() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Thank you.", segment: 9))
        writer.append(.resumed)
        writer.close()
        #expect(body(url) == ["[10:30:12] Thank you.", "[10:30:12] —— 繼續 ——"])
    }
}
