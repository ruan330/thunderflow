import Testing
import ThunderUI

/// 即時翻譯頁的來源選單（DESIGN.md 4.3 節，D35）：錄音中、暫停中都能換來源，接著錄同一場。
@Suite("來源選單：什麼時候能換來源（D35）")
struct SourceMenuTests {
    @Test("還沒開始、錄音中、暫停中都能換來源")
    func enabledWhenIdleRecordingOrPaused() {
        for phase in [RecorderPhase.idle, .recording, .paused] {
            #expect(SourceMenu.isEnabled(phase: phase, switching: false, recordingFromFile: false), "\(phase)")
        }
    }

    @Test("開始中、收尾中不能換：收音正在開始或結束")
    func disabledWhileStartingOrStopping() {
        for phase in [RecorderPhase.starting, .stopping] {
            #expect(!SourceMenu.isEnabled(phase: phase, switching: false, recordingFromFile: false), "\(phase)")
        }
    }

    @Test("正在換來源時不能再換：等這一次換好（通常不到半秒）")
    func disabledWhileSwitching() {
        #expect(!SourceMenu.isEnabled(phase: .recording, switching: true, recordingFromFile: false))
        #expect(!SourceMenu.isEnabled(phase: .paused, switching: true, recordingFromFile: false))
    }

    @Test("用音檔當來源（測試用）錄音時不能換：音檔播完就會自動停止，換掉之後這個規則就不成立")
    func disabledWhileRecordingFromAFile() {
        #expect(!SourceMenu.isEnabled(phase: .recording, switching: false, recordingFromFile: true))
        #expect(!SourceMenu.isEnabled(phase: .paused, switching: false, recordingFromFile: true))
        // 還沒開始時可以從音檔換回別的來源
        #expect(SourceMenu.isEnabled(phase: .idle, switching: false, recordingFromFile: true))
    }

    @Test("音檔只在還沒開始時能選：錄音中不能換成音檔")
    func fileOnlyWhenIdle() {
        #expect(SourceMenu.offersFile(phase: .idle))
        for phase in [RecorderPhase.starting, .recording, .paused, .stopping] {
            #expect(!SourceMenu.offersFile(phase: phase), "\(phase)")
        }
    }
}
