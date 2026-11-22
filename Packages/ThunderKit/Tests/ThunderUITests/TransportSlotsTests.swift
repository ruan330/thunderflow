import Testing
import ThunderUI

@Suite("開始／停止：主要位置與左邊的停止位置")
struct TransportSlotsTests {
    @Test("尚未開始：主要位置是開始錄音；開始中「準備中」還沒出現時仍是開始錄音，出現之後才換成準備中；都沒有停止鈕")
    func beforeRecording() {
        let idle = TransportSlots(phase: .idle, preparingVisible: false)
        #expect(idle.main == .start)
        #expect(!idle.showsStop)

        let held = TransportSlots(phase: .starting, preparingVisible: false)
        #expect(held.main == .start)
        #expect(!held.showsStop)

        let preparing = TransportSlots(phase: .starting, preparingVisible: true)
        #expect(preparing.main == .preparing)
        #expect(!preparing.showsStop)

        #expect(TransportSlots(phase: .idle, preparingVisible: true).main == .start, "準備中只在開始中出現")
    }

    @Test("錄音中：主要位置是暫停；暫停時：主要位置是繼續；兩者的停止鈕都在左邊的停止位置")
    func recordingAndPaused() {
        let recording = TransportSlots(phase: .recording, preparingVisible: false)
        #expect(recording.main == .pause)
        #expect(recording.showsStop)

        let paused = TransportSlots(phase: .paused, preparingVisible: false)
        #expect(paused.main == .resume)
        #expect(paused.showsStop)
    }

    @Test("收尾中：主要位置顯示收尾中，沒有停止鈕")
    func stopping() {
        let slots = TransportSlots(phase: .stopping, preparingVisible: false)
        #expect(slots.main == .finishing)
        #expect(!slots.showsStop)
    }

    @Test("錄音中與暫停時，停止鈕不會在主要位置")
    func stopNeverInMainSlot() {
        for phase in RecorderPhase.allCases {
            for preparingVisible in [false, true] {
                let slots = TransportSlots(phase: phase, preparingVisible: preparingVisible)
                switch phase {
                case .recording, .paused:
                    #expect(slots.showsStop, "\(phase)：停止鈕在左邊的停止位置")
                    #expect(slots.main == (phase == .recording ? .pause : .resume), "\(phase)：主要位置是暫停或繼續")
                default:
                    #expect(!slots.showsStop, "\(phase)：只有錄音中與暫停時有停止鈕")
                }
            }
        }
    }
}
