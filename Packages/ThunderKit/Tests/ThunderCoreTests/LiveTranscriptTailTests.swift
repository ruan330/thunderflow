import Foundation
import Testing
import ThunderCore
import ThunderTestKit

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// 切段的「晚到的尾巴」（2026-11-25 實測的事件順序）：停頓切出一段之後，晚到的一兩個字先以**下一段的增量**送出，
/// 接著上一段再確定一次、把它們併回去，下一段重新從空的開始。所以下一段剛開始有字，還不能把上一段寫出去。
@Suite("即時逐字稿：晚到的尾巴併回上一段之後才寫（D34）")
struct LiveTranscriptTailTests {
    /// 計時設得很長：只有字數與確定的順序會讓一段寫出去。
    private func makeWriter(in tmp: TemporaryDirectory) throws -> (LiveTranscriptWriter, URL) {
        let url = tmp.url.appendingPathComponent("live-transcript.txt")
        let writer = try LiveTranscriptWriter(
            url: url, title: "GameDay", startedAt: at("2026-12-01T10:30:00Z"), timeZone: TimeZone(identifier: "UTC")!,
            settleDelay: .seconds(60), clock: { at("2026-12-01T10:30:12Z") })
        return (writer, url)
    }

    private func body(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").map(String.init).dropFirst(2))
    }

    @Test("晚到的尾巴先以下一段的字送出時，上一段不寫；併回之後下一段一有字，就寫出補完的那一句")
    func tailMergedBack() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Good morning everyone, and welcome to the", segment: 0))
        writer.append(.words(" conference", segment: 1))
        writer.append(.words(".", segment: 1))
        #expect(body(url).isEmpty)
        writer.append(.speech("Good morning everyone, and welcome to the conference.", segment: 0))
        #expect(body(url).isEmpty)
        writer.append(.words(" Today", segment: 1))
        #expect(body(url) == ["[10:30:12] Good morning everyone, and welcome to the conference."])
        writer.close()
    }

    @Test("下一段超過 2 個字就不可能是晚到的尾巴：上一段寫出去")
    func moreThanTwoWords() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Each team gets its own account.", segment: 3))
        writer.append(.words(" Today", segment: 4))
        writer.append(.words(" I", segment: 4))
        #expect(body(url).isEmpty)
        writer.append(.words(" want", segment: 4))
        #expect(body(url) == ["[10:30:12] Each team gets its own account."])
        writer.close()
    }

    @Test("一個字被切成好幾個增量（Bed、rock）時算一個字")
    func splitWordCountsOnce() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Welcome.", segment: 0))
        writer.append(.words(" Amazon", segment: 1))
        writer.append(.words(" Bed", segment: 1))
        writer.append(.words("rock", segment: 1))
        #expect(body(url).isEmpty)
        writer.append(.words(" Agent", segment: 1))
        #expect(body(url) == ["[10:30:12] Welcome."])
        writer.close()
    }

    @Test("只補上標點（字數沒變）不算併入尾巴：下一段還是要超過 2 個字才寫")
    func punctuationOnlyIsNotATail() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Hello there", segment: 0))
        writer.append(.speech("Hello there.", segment: 0))
        writer.append(.words(" Today", segment: 1))
        #expect(body(url).isEmpty)
        writer.append(.words(" I want", segment: 1))
        #expect(body(url) == ["[10:30:12] Hello there."])
        writer.close()
    }

    @Test("同一段或更早的段的字不算下一段")
    func ownWordsIgnored() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let (writer, url) = try makeWriter(in: tmp)
        writer.append(.speech("Hello there.", segment: 2))
        writer.append(.words(" one two three four", segment: 2))
        writer.append(.words(" one two three four", segment: 1))
        #expect(body(url).isEmpty)
        writer.close()
        #expect(body(url) == ["[10:30:12] Hello there."])
    }
}
