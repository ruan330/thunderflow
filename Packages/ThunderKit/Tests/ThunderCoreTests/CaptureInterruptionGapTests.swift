import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 錄音中斷（睡眠、裝置不見、換了輸出裝置）寫進日誌的方式（DESIGN.md 2.3 節第 9 條、5.4 節）：
/// 在中斷的音訊時間記一筆長度是 0 的缺口，帶原因與沒有錄到的時間（實際經過的秒數）。
/// 只增不改：舊的讀取端把不認識的原因當成 unknown、略過不認識的欄位；長度是 0，不影響沒翻譯到的長度。
@Suite("日誌：錄音中斷")
struct CaptureInterruptionGapTests {
    @Test(
        "錄音中斷寫成一筆長度是 0 的缺口：音訊時間、原因、沒有錄到多久都寫進日誌，讀回來一樣",
        arguments: [GapReason.sleep, .deviceLost, .outputChanged, .captureStalled])
    func roundTrip(reason: GapReason) throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let interruption = AudioGap.interruption(at: AudioTime(seconds: 120), lostSeconds: 845.25, reason: reason)
        let writer = try JournalWriter(url: url)
        try writer.append(.gap(interruption))
        writer.close()

        let line = try String(contentsOf: url, encoding: .utf8)
        #expect(line == #"{"k":"gap","from":120,"to":120,"why":"\#(reason.rawValue)","lost":845.25}"# + "\n")
        #expect(try JournalReader.read(url).entries == [.gap(interruption)])
        #expect(interruption.duration == 0)
        #expect(interruption.isInterruption)
    }

    @Test("一般的缺口照舊：不寫 lost；沒有 lost 的紀錄讀回來是 0，不算中斷")
    func ordinaryGapsAreUnchanged() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let gap = AudioGap(from: AudioTime(seconds: 30), to: AudioTime(seconds: 42.5), reason: .network)
        let writer = try JournalWriter(url: url)
        try writer.append(.gap(gap))
        writer.close()

        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"k":"gap","from":30,"to":42.5,"why":"network"}"# + "\n")
        let read = try JournalReader.read(url).entries
        #expect(read == [.gap(gap)])
        #expect(gap.lostSeconds == 0)
        #expect(!gap.isInterruption)
    }

    @Test("同一個時間點、同一種原因的中斷合併時，沒有錄到的時間加總")
    func coalescingAddsTheLostTime() {
        let first = AudioGap.interruption(at: AudioTime(seconds: 60), lostSeconds: 2, reason: .deviceLost)
        let second = AudioGap.interruption(at: AudioTime(seconds: 60), lostSeconds: 3, reason: .deviceLost)

        #expect(
            AudioGap.coalesced([first, second])
                == [AudioGap.interruption(at: AudioTime(seconds: 60), lostSeconds: 5, reason: .deviceLost)])
    }
}
