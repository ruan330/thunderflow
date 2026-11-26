import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 錄音中換音訊來源（D35）：日誌在換的位置記一筆長度是 0 的缺口（`sourceChanged`，帶之後用的來源），
/// 段落在那裡結束，`transcript.md` 與即時逐字稿寫出「〔音訊來源：…〕」。只增不改：`schemaVersion` 維持 1。
@Suite("換音訊來源：日誌、段落與逐字稿的標示（D35）")
struct SourceChangeTests {
    private func source(_ text: String, at time: Double, seg: Int) -> JournalEntry {
        .source(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
    }

    private func translation(_ text: String, at time: Double, seg: Int) -> JournalEntry {
        .translation(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
    }

    private func switched(at time: Double, to name: String?, lost: Double = 0.15) -> AudioGap {
        .interruption(at: AudioTime(seconds: time), lostSeconds: lost, reason: .sourceChanged, source: name)
    }

    @Test("日誌記下換來源的位置、沒有錄到多久與之後用的來源，讀回來一模一樣；名稱裡的引號與換行照 JSON 跳脫")
    func journalRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let gap = switched(at: 95, to: "MacBook Pro 麥克風", lost: 0.125)
        let odd = switched(at: 96, to: "Bob 的 \"USB\"\n麥克風")
        let writer = try JournalWriter(url: url)
        try writer.append(.gap(gap))
        try writer.append(.gap(odd))
        writer.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == #"{"k":"gap","from":95,"to":95,"why":"sourceChanged","lost":0.125,"src":"MacBook Pro 麥克風"}"#)
        #expect(try JournalReader.read(url).entries == [.gap(gap), .gap(odd)])
        #expect(gap.isInterruption)
        #expect(gap.duration == 0)
    }

    @Test("用 Codable 寫出的紀錄也帶之後用的來源，讀得回來；其他缺口沒有這個欄位")
    func codableRoundTrip() throws {
        let gap = switched(at: 12, to: "系統音訊")
        let data = try JSONEncoder().encode(JournalEntry.gap(gap))
        #expect(String(decoding: data, as: UTF8.self).contains(#""src":"系統音訊""#))
        #expect(try JSONDecoder().decode(JournalEntry.self, from: data) == .gap(gap))

        let network = JournalEntry.gap(AudioGap(from: AudioTime(seconds: 30), to: AudioTime(seconds: 42.5), reason: .network))
        #expect(!String(decoding: try JSONEncoder().encode(network), as: UTF8.self).contains("src"))
    }

    @Test("逐字稿的標示寫出之後用的來源；沒有錄到的時間 1 秒以上才寫出來")
    func label() {
        #expect(
            TranscriptInterruption(at: 10, reason: .sourceChanged, lostSeconds: 0.2, source: "MacBook Pro 麥克風").label
                == "〔音訊來源：MacBook Pro 麥克風〕")
        #expect(
            TranscriptInterruption(at: 10, reason: .sourceChanged, lostSeconds: 3, source: "系統音訊").label
                == "〔音訊來源：系統音訊，約 3 秒沒有錄到〕")
        #expect(TranscriptInterruption(at: 10, reason: .sourceChanged, lostSeconds: 0.2).label == "〔換了音訊來源〕")
        // 其他原因照舊
        #expect(
            TranscriptInterruption(at: 12, reason: .sleep, lostSeconds: 845.25).label == "〔錄音中斷：電腦睡眠，約 14 分鐘沒有錄到〕")
    }

    @Test("段落：換來源的地方結束段落，標示記在下一個段落前面，帶之後用的來源")
    func endsTheBlock() {
        let entries: [JournalEntry] = [
            source("From the speakers.", at: 10, seg: 0), translation("從喇叭來的。", at: 11, seg: 0),
            .gap(switched(at: 12, to: "MacBook Pro 麥克風")),
            source("From the room.", at: 13, seg: 1), translation("從現場來的。", at: 14, seg: 1),
        ]

        let blocks = TranscriptBlocks.build(from: entries).blocks

        #expect(blocks.count == 2)
        #expect(
            blocks.last?.interruptionsBefore
                == [TranscriptInterruption(at: 12, reason: .sourceChanged, lostSeconds: 0.15, source: "MacBook Pro 麥克風")])
    }

    @Test("blocks.jsonl 的標示多一個 src 欄位，讀回來一樣；其他中斷和以前一模一樣")
    func blocksFileRoundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")
        let blocks = [
            TranscriptBlock(
                id: 0, start: 13, en: "From the room.", segments: [1],
                interruptionsBefore: [
                    TranscriptInterruption(at: 12, reason: .sourceChanged, lostSeconds: 0.15, source: "MacBook Pro 麥克風"),
                    TranscriptInterruption(at: 12.5, reason: .deviceLost, lostSeconds: 3.2),
                ])
        ]

        try TranscriptBlocks.write(blocks, to: url)

        let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).first
        #expect(
            line
                == #"{"id":0,"start":13,"en":"From the room.","zh":"","segments":[1],"marked":false,"before":[{"at":12,"why":"sourceChanged","lost":0.15,"src":"MacBook Pro 麥克風"},{"at":12.5,"why":"deviceLost","lost":3.2}]}"#
        )
        #expect(try TranscriptBlocks.read(url) == blocks)
    }

    @Test("transcript.md 在換來源的位置寫出「〔音訊來源：…〕」")
    func markdown() {
        let meta = SessionMeta(title: "測試", startedAt: Date(timeIntervalSince1970: 1_796_178_600), state: .complete)
        let blocks = [
            TranscriptBlock(id: 0, start: 8, en: "From the speakers.", zh: "從喇叭來的。", segments: [0]),
            TranscriptBlock(
                id: 1, start: 13, en: "From the room.", zh: "從現場來的。", segments: [1],
                interruptionsBefore: [
                    TranscriptInterruption(at: 12, reason: .sourceChanged, lostSeconds: 0.15, source: "MacBook Pro 麥克風")
                ]),
        ]

        let text = TranscriptMarkdown.render(meta: meta, blocks: blocks, timeZone: TimeZone(identifier: "Asia/Taipei")!)

        #expect(
            text.hasSuffix(
                "\n### 00:00:08\nFrom the speakers.\n\n從喇叭來的。\n"
                    + "\n〔音訊來源：MacBook Pro 麥克風〕\n"
                    + "\n### 00:00:13\nFrom the room.\n\n從現場來的。\n"))
    }

    @Test("即時逐字稿：換來源寫成一行「〔音訊來源：…〕」")
    func liveTranscriptLine() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("live-transcript.txt")
        let start = ISO8601DateFormatter().date(from: "2026-12-01T10:30:00Z")!
        let writer = try LiveTranscriptWriter(
            url: url, title: "GameDay", startedAt: start, timeZone: TimeZone(identifier: "UTC")!,
            settleDelay: .seconds(60), clock: { start.addingTimeInterval(72) })

        writer.append(.gap(switched(at: 60, to: "MacBook Pro 麥克風")))
        writer.close()

        let body = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).dropFirst(2)
        #expect(Array(body) == ["[10:31:12] 〔音訊來源：MacBook Pro 麥克風〕"])
    }
}
