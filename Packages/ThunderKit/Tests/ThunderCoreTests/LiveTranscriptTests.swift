import Foundation
import Synchronization
import Testing
import ThunderCore
import ThunderTestKit

/// 每讀一次就往後走一格的假時鐘（走到最後一格就停在那裡）：看得出每一行用的是寫入當下的時刻。
private final class SteppingClock: Sendable {
    private let times: Mutex<[Date]>

    init(_ times: [Date]) { self.times = Mutex(times) }

    func now() -> Date { times.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

private let utc = TimeZone(identifier: "UTC")!

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private let howToRead = "# 英文由語音自動辨識，可能有錯字；⚑ 是使用者標記的重點"

@Suite("即時逐字稿 live-transcript.txt：給 AI agent 讀的純文字（D34）")
struct LiveTranscriptTests {
    private func makeWriter(
        in tmp: TemporaryDirectory, title: String = "GameDay", times: [String] = ["2026-12-01T10:30:12Z"]
    ) throws -> (LiveTranscriptWriter, URL) {
        let url = tmp.url.appendingPathComponent("live-transcript.txt")
        let clock = SteppingClock(times.map(at))
        let writer = try LiveTranscriptWriter(
            url: url, title: title, startedAt: at("2026-12-01T10:30:00Z"), timeZone: utc, clock: { clock.now() })
        return (writer, url)
    }

    /// 檔案的每一行（最後的換行之後沒有東西，不算一行）。
    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// 兩行說明之後的內容。
    private func body(_ url: URL) throws -> [String] { Array(try lines(url).dropFirst(2)) }

    @Test("建立時寫入兩行說明：標題與開始的時間，以及怎麼讀這個檔；每一行都以換行結尾")
    func header() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.close()
        #expect(
            try String(contentsOf: url, encoding: .utf8)
                == "# ThunderFlow 即時逐字稿｜GameDay｜2026-12-01 10:30 開始\n\(howToRead)\n")
    }

    @Test("沒有標題時，說明裡不寫標題")
    func untitled() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, title: "  ")
        writer.close()
        #expect(try lines(url) == ["# ThunderFlow 即時逐字稿｜2026-12-01 10:30 開始", howToRead])
    }

    @Test("每段英文寫一行，前面是寫入當下的時刻（時:分:秒）")
    func speech() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp, times: ["2026-12-01T10:30:12Z", "2026-12-01T11:02:33Z"])
        writer.append(.speech("So today each team gets its own AWS account.", segment: 0))
        writer.append(.speech("Okay, quick announcement.", segment: 1))
        writer.close()
        #expect(
            try body(url) == [
                "[10:30:12] So today each team gets its own AWS account.",
                "[11:02:33] Okay, quick announcement.",
            ])
    }

    @Test("同一段又確定一次（補上晚到的標點）時不重寫；下一段照寫")
    func amendedSegment() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Hello there", segment: 3))
        writer.append(.speech("Hello there.", segment: 3))
        writer.append(.speech("Next one.", segment: 4))
        writer.close()
        #expect(try body(url) == ["[10:30:12] Hello there", "[10:30:12] Next one."])
    }

    @Test("沒有段號的英文每次都寫")
    func unsegmented() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("One.", segment: nil))
        writer.append(.speech("One.", segment: nil))
        writer.close()
        #expect(try body(url) == ["[10:30:12] One.", "[10:30:12] One."])
    }

    @Test("英文裡的換行換成空白、前後的空白去掉，一段只占一行；只有空白的不寫")
    func oneLinePerSegment() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("  First line\nsecond\r\nthird  ", segment: 0))
        writer.append(.speech(" \n ", segment: 1))
        writer.close()
        #expect(try body(url) == ["[10:30:12] First line second third"])
    }

    @Test("標記、暫停、繼續各寫一行")
    func controls() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.marker)
        writer.append(.paused)
        writer.append(.resumed)
        writer.close()
        #expect(try body(url) == ["[10:30:12] ⚑ 標記", "[10:30:12] —— 暫停 ——", "[10:30:12] —— 繼續 ——"])
    }

    @Test("引擎回報的缺口寫成「約多久沒有字幕」與原因")
    func engineGaps() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.gap(AudioGap(from: AudioTime(seconds: 10), to: AudioTime(seconds: 22), reason: .network)))
        writer.append(.gap(AudioGap(from: AudioTime(seconds: 30), to: AudioTime(seconds: 30.4), reason: .network)))
        writer.append(.gap(AudioGap(from: AudioTime(seconds: 40), to: AudioTime(seconds: 165), reason: .backpressure)))
        writer.append(.gap(AudioGap(from: AudioTime(seconds: 200), to: AudioTime(seconds: 230), reason: .engineStopped)))
        writer.close()
        #expect(
            try body(url) == [
                "[10:30:12] 〔約 12 秒沒有字幕：網路中斷〕",
                "[10:30:12] 〔不到 1 秒沒有字幕：網路中斷〕",
                "[10:30:12] 〔約 2 分鐘沒有字幕：辨識跟不上〕",
                "[10:30:12] 〔約 30 秒沒有字幕：辨識停止〕",
            ])
    }

    @Test("錄音中斷寫成和逐字稿相同的說明")
    func interruption() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.gap(.interruption(at: AudioTime(seconds: 120), lostSeconds: 845.25, reason: .sleep)))
        writer.close()
        #expect(try body(url) == ["[10:30:12] 〔錄音中斷：電腦睡眠，約 14 分鐘沒有錄到〕"])
    }

    @Test("關檔之後再寫不會出錯，也不會寫進去；重複關檔也不會出錯")
    func afterClose() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.marker)
        writer.close()
        writer.append(.speech("Too late.", segment: 9))
        writer.close()
        #expect(try body(url) == ["[10:30:12] ⚑ 標記"])
    }

    @Test("好幾條執行緒同時寫，每一行都完整、不會交錯")
    func concurrentAppends() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<50 { writer.append(.marker) } }
            }
        }
        writer.close()
        let lines = try body(url)
        #expect(lines.count == 400)
        #expect(lines.allSatisfy { $0 == "[10:30:12] ⚑ 標記" })
    }

    @Test("即時逐字稿與教材資料夾在場次資料夾的第一層，跟著資料夾搬家")
    func locations() {
        let directory = SessionDirectory(url: URL(fileURLWithPath: "/tmp/2026-12-01 1030 GameDay", isDirectory: true))
        #expect(directory.liveTranscriptURL.path == "/tmp/2026-12-01 1030 GameDay/live-transcript.txt")
        #expect(directory.workshopURL.path == "/tmp/2026-12-01 1030 GameDay/workshop")
    }
}
