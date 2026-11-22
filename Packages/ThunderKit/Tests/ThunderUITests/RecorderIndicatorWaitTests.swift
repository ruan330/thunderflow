import Testing
import ThunderUI

@Suite("狀態列的錄音狀態：和開始／停止的按鈕同時換，0.3 秒內就開始錄音時不閃一下「準備中」")
struct RecorderIndicatorWaitTests {
    @Test("開始中、「準備中」還沒出現：狀態列仍顯示尚未開始，之後直接變成錄音中")
    func startingBeforeReveal() {
        #expect(Indicator.recorder(.starting, preparingVisible: false) == Indicator.recorder(.idle))
    }

    @Test("開始中、等滿 0.3 秒：狀態列顯示準備中")
    func startingAfterReveal() {
        #expect(Indicator.recorder(.starting, preparingVisible: true) == Indicator.recorder(.starting))
    }

    @Test("尚未開始、錄音中、已暫停：不受「準備中」有沒有出現影響")
    func settledPhases() {
        for phase in [RecorderPhase.idle, .recording, .paused] {
            for visible in [false, true] {
                #expect(Indicator.recorder(phase, preparingVisible: visible) == Indicator.recorder(phase), "\(phase)")
            }
        }
    }

    @Test("狀態列和按鈕一致：按鈕顯示準備中或收尾中時，狀態列才顯示等待的轉圈")
    func matchesTransport() {
        for phase in RecorderPhase.allCases {
            for visible in [false, true] {
                let main = TransportSlots(phase: phase, preparingVisible: visible).main
                let buttonWaits = main == .preparing || main == .finishing
                let stripWaits = Indicator.recorder(phase, preparingVisible: visible).symbol == .spinner
                #expect(stripWaits == buttonWaits, "\(phase)，準備中\(visible ? "已" : "未")出現")
            }
        }
    }
}
