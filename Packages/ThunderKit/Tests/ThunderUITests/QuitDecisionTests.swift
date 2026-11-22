import Testing
import ThunderUI

@Suite("結束 App 時的錄音：沒在錄就直接結束，使用者結束時先問，系統登出或關機時先停好再結束")
struct QuitDecisionTests {
    @Test("沒有在錄音：直接結束（使用者結束或系統關機都一樣）")
    func idle() {
        #expect(QuitDecision(phase: .idle, systemPoweringOff: false) == .now)
        #expect(QuitDecision(phase: .idle, systemPoweringOff: true) == .now)
    }

    @Test("錄音中或暫停時，使用者按 ⌘Q 或選單的「結束」：先問要不要停止錄音並結束")
    func userQuitWhileRecording() {
        #expect(QuitDecision(phase: .recording, systemPoweringOff: false) == .ask)
        #expect(QuitDecision(phase: .paused, systemPoweringOff: false) == .ask)
    }

    @Test("錄音中或暫停時，系統要登出、重新開機或關機：不問，先把這一場停好再結束")
    func powerOffWhileRecording() {
        #expect(QuitDecision(phase: .recording, systemPoweringOff: true) == .stopFirst)
        #expect(QuitDecision(phase: .paused, systemPoweringOff: true) == .stopFirst)
    }

    @Test("開始中：使用者結束時先問；系統關機時不問，等它開始之後停好再結束")
    func starting() {
        #expect(QuitDecision(phase: .starting, systemPoweringOff: false) == .ask)
        #expect(QuitDecision(phase: .starting, systemPoweringOff: true) == .stopFirst)
    }

    @Test("收尾中（已經按了停止）：不問，等它停完再結束")
    func stopping() {
        #expect(QuitDecision(phase: .stopping, systemPoweringOff: false) == .stopFirst)
        #expect(QuitDecision(phase: .stopping, systemPoweringOff: true) == .stopFirst)
    }
}
