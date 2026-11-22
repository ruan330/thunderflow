import Testing
import ThunderUI

@Suite("錄音的指令：依實際的階段決定能不能用")
struct RecordingCommandsTests {
    @Test("尚未開始：只能開始錄音，不能暫停、停止或標記重點")
    func idle() {
        let commands = RecordingCommands(phase: .idle)
        #expect(commands.canStart)
        #expect(!commands.canTogglePause)
        #expect(!commands.canStop)
        #expect(!commands.canMark)
    }

    @Test("錄音中：可以暫停、停止、標記重點，不能再開始一場")
    func recording() {
        let commands = RecordingCommands(phase: .recording)
        #expect(!commands.canStart)
        #expect(commands.canTogglePause)
        #expect(commands.canStop)
        #expect(commands.canMark)
    }

    @Test("暫停時：可以繼續、停止、標記重點，不能再開始一場")
    func paused() {
        let commands = RecordingCommands(phase: .paused)
        #expect(!commands.canStart)
        #expect(commands.canTogglePause)
        #expect(commands.canStop)
        #expect(commands.canMark)
    }

    @Test("開始中：什麼都不能做（不會開始第二場，也還沒有東西可以暫停、停止或標記）")
    func starting() {
        let commands = RecordingCommands(phase: .starting)
        #expect(!commands.canStart)
        #expect(!commands.canTogglePause)
        #expect(!commands.canStop)
        #expect(!commands.canMark)
    }

    @Test("收尾中：不能暫停或繼續（不會把狀態改回錄音中、再停止一次），也不能停止、標記或開始")
    func stopping() {
        let commands = RecordingCommands(phase: .stopping)
        #expect(!commands.canTogglePause)
        #expect(!commands.canStop)
        #expect(!commands.canMark)
        #expect(!commands.canStart)
    }

    @Test("暫停的指令名稱：暫停時是「繼續」，其他時候是「暫停」")
    func pauseTitle() {
        for phase in RecorderPhase.allCases {
            #expect(RecordingCommands(phase: phase).pauseTitle == (phase == .paused ? "繼續" : "暫停"), "\(phase)")
        }
    }
}
