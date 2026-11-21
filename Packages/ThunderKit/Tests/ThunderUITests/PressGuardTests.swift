import Testing
import ThunderUI

@Suite("防連點：狀態改變後 0.5 秒內的點擊不算數")
struct PressGuardTests {
    @Test("還沒有狀態改變過時，點擊一律算數")
    func neverChanged() {
        let pressGuard = PressGuard()
        #expect(pressGuard.accepts(at: ms(0)))
        #expect(pressGuard.accepts(at: ms(10_000)))
    }

    @Test("狀態改變後未滿 0.5 秒的點擊不算數；剛好 0.5 秒與之後就算數")
    func window() {
        var pressGuard = PressGuard()
        pressGuard.stateChanged(at: ms(0))
        #expect(!pressGuard.accepts(at: ms(0)))
        #expect(!pressGuard.accepts(at: ms(499)))
        #expect(pressGuard.accepts(at: ms(500)))
        #expect(pressGuard.accepts(at: ms(501)))
    }

    @Test("狀態再次改變時，從新的時間點重新計算 0.5 秒")
    func restarts() {
        var pressGuard = PressGuard()
        pressGuard.stateChanged(at: ms(0))
        pressGuard.stateChanged(at: ms(400))
        #expect(!pressGuard.accepts(at: ms(500)), "離第一次改變已經 0.5 秒，離第二次只有 0.1 秒")
        #expect(!pressGuard.accepts(at: ms(899)))
        #expect(pressGuard.accepts(at: ms(900)))
    }
}
