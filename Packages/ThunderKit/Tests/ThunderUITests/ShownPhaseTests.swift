import Testing
import ThunderUI

@Suite("畫面上表示的階段：開始中與收尾中未滿 0.3 秒時，維持等待之前的樣子")
struct ShownPhaseTests {
    @Test("開始中、「準備中」還沒出現：畫面仍是尚未開始；出現之後才是開始中")
    func starting() {
        #expect(RecorderPhase.starting.shown(before: .idle, waitVisible: false) == .idle)
        #expect(RecorderPhase.starting.shown(before: .idle, waitVisible: true) == .starting)
    }

    @Test("收尾中、「收尾中」還沒出現：畫面維持錄音中或已暫停；出現之後才是收尾中")
    func stopping() {
        #expect(RecorderPhase.stopping.shown(before: .recording, waitVisible: false) == .recording)
        #expect(RecorderPhase.stopping.shown(before: .paused, waitVisible: false) == .paused)
        #expect(RecorderPhase.stopping.shown(before: .recording, waitVisible: true) == .stopping)
        #expect(RecorderPhase.stopping.shown(before: .paused, waitVisible: true) == .stopping)
    }

    @Test("尚未開始、錄音中、已暫停：照實際的階段顯示")
    func settledPhases() {
        for phase in [RecorderPhase.idle, .recording, .paused] {
            for before in [RecorderPhase.idle, .recording, .paused] {
                for visible in [false, true] {
                    #expect(phase.shown(before: before, waitVisible: visible) == phase, "\(phase)")
                }
            }
        }
    }

    @Test("0.3 秒內就停好：按鈕從暫停直接變回開始錄音，停止鈕留到最後，狀態列不經過收尾中")
    func quickStop() {
        // 錄音中 → 按下停止（收尾中，還沒滿 0.3 秒）→ 尚未開始
        let shown = [
            RecorderPhase.recording.shown(before: .recording, waitVisible: false),
            RecorderPhase.stopping.shown(before: .recording, waitVisible: false),
            RecorderPhase.idle.shown(before: .idle, waitVisible: false),
        ]
        let slots = shown.map { TransportSlots(phase: $0, preparingVisible: false) }
        #expect(slots.map(\.main) == [.pause, .pause, .start])
        #expect(slots.map(\.showsStop) == [true, true, false])
        #expect(!shown.map { Indicator.recorder($0).text }.contains("收尾中"))
    }

    @Test("0.3 秒內就開始錄音：按鈕從開始錄音直接變成暫停，狀態列不經過準備中")
    func quickStart() {
        // 尚未開始 → 按下開始（開始中，還沒滿 0.3 秒）→ 錄音中
        let shown = [
            RecorderPhase.idle.shown(before: .idle, waitVisible: false),
            RecorderPhase.starting.shown(before: .idle, waitVisible: false),
            RecorderPhase.recording.shown(before: .recording, waitVisible: false),
        ]
        let slots = shown.map { TransportSlots(phase: $0, preparingVisible: false) }
        #expect(slots.map(\.main) == [.start, .start, .pause])
        #expect(!shown.map { Indicator.recorder($0).text }.contains("準備中"))
    }
}
