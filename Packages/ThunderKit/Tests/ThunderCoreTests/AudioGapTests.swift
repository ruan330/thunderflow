import Testing
import ThunderCore

@Suite("AudioGap：合併沒翻譯到的區段")
struct AudioGapTests {
    private func gap(_ from: Double, _ to: Double, _ reason: GapReason = .network) -> AudioGap {
        AudioGap(from: AudioTime(seconds: from), to: AudioTime(seconds: to), reason: reason)
    }

    @Test("相連、原因相同的缺口合併成一筆")
    func mergesAdjacent() {
        #expect(AudioGap.coalesced([gap(0, 1), gap(1, 2), gap(2, 2.5)]) == [gap(0, 2.5)])
    }

    @Test("重疊的缺口合併成一筆")
    func mergesOverlapping() {
        #expect(AudioGap.coalesced([gap(0, 3), gap(2, 5)]) == [gap(0, 5)])
        #expect(AudioGap.coalesced([gap(0, 10), gap(2, 5)]) == [gap(0, 10)])
    }

    @Test("中間有空隙就不合併")
    func keepsSeparated() {
        #expect(AudioGap.coalesced([gap(0, 1), gap(1.5, 2)]) == [gap(0, 1), gap(1.5, 2)])
    }

    @Test("誤差 1 毫秒以內視為相連")
    func toleratesTinySeams() {
        #expect(AudioGap.coalesced([gap(0, 1), gap(1.0005, 2)]) == [gap(0, 2)])
        #expect(AudioGap.coalesced([gap(0, 1), gap(1.01, 2)]).count == 2)
    }

    @Test("輸入順序不影響結果，輸出依開始時間排序")
    func sortsInput() {
        #expect(AudioGap.coalesced([gap(4, 5), gap(0, 1), gap(1, 2)]) == [gap(0, 2), gap(4, 5)])
    }

    @Test("原因不同的缺口不合併")
    func keepsDifferentReasonsApart() {
        let gaps = [gap(0, 1, .network), gap(1, 2, .backpressure)]
        #expect(AudioGap.coalesced(gaps) == gaps)
    }

    @Test("空陣列還是空陣列；長度是結束減開始")
    func basics() {
        #expect(AudioGap.coalesced([]).isEmpty)
        #expect(gap(30, 42.5).duration == 12.5)
    }
}
