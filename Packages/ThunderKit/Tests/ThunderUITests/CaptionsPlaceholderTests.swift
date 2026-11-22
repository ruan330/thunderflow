import Testing
import ThunderUI

@Suite("字幕區還沒有字幕時的說明：按下開始之後就不再叫使用者按開始")
struct CaptionsPlaceholderTests {
    @Test("尚未開始：請使用者按下「開始錄音」，符號是閃電")
    func idle() {
        let placeholder = CaptionsPlaceholder(phase: .idle)
        #expect(placeholder.title == "按下「開始錄音」")
        #expect(placeholder.symbol == .bolt)
    }

    @Test("開始中與錄音中、第一句字幕還沒出現：顯示正在聆聽，符號是閃電")
    func listening() {
        for phase in [RecorderPhase.starting, .recording] {
            let placeholder = CaptionsPlaceholder(phase: phase)
            #expect(placeholder.title == "正在聆聽", "\(phase)")
            #expect(placeholder.symbol == .bolt, "\(phase)")
        }
    }

    @Test("暫停時：顯示已暫停與暫停符號，並說明按「繼續」接著錄")
    func paused() {
        let placeholder = CaptionsPlaceholder(phase: .paused)
        #expect(placeholder.title == "已暫停")
        #expect(placeholder.symbol == .pause)
        #expect(placeholder.message.contains("「繼續」"))
    }

    @Test("收尾中：和尚未開始一樣（沒有字幕的一場結束後，回到請使用者按開始）")
    func stopping() {
        #expect(CaptionsPlaceholder(phase: .stopping) == CaptionsPlaceholder(phase: .idle))
    }

    @Test("按下開始之後到停止之前，標題與說明都不會叫使用者按「開始錄音」")
    func neverAsksToStartWhileRecording() {
        for phase in [RecorderPhase.starting, .recording, .paused] {
            let placeholder = CaptionsPlaceholder(phase: phase)
            #expect(!placeholder.title.contains("開始錄音"), "\(phase)")
            #expect(!placeholder.message.contains("開始錄音"), "\(phase)")
        }
    }
}
