import Testing
import ThunderUI

/// 錄音中一直收不到聲音時要不要提醒（DESIGN.md 5.4 節）。按下開始之後才去播放影片是正常的用法，不能被當成權限問題。
@Suite("收不到聲音時的提醒")
struct SilenceWarningTests {
    @Test("系統音訊：沒有任何程式在出聲時，再久的靜音都不提醒（按下開始之後才去播放影片是正常的用法）")
    func systemAudioWithNobodyPlayingIsNormal() {
        for quiet in [6.0, 60, 600] {
            #expect(SilenceWarning.check(source: .systemAudio, quietSeconds: quiet, heardSound: false, othersPlayingSeconds: 0) == nil)
        }
    }

    @Test("系統音訊：別的程式持續出聲、這裡卻一直收到靜音，才提醒去允許錄製系統音訊")
    func systemAudioWarnsWhenOthersPlayButNothingArrives() {
        #expect(SilenceWarning.check(source: .systemAudio, quietSeconds: 6, heardSound: false, othersPlayingSeconds: 1) == .systemAudio)
        #expect(SilenceWarning.check(source: .systemAudio, quietSeconds: 45, heardSound: false, othersPlayingSeconds: 8) == .systemAudio)
    }

    @Test("系統音訊：別的程式剛開始出聲（不到 1 秒），聲音可能還沒傳到這裡，先不提醒")
    func systemAudioWaitsWhenOthersJustStarted() {
        #expect(SilenceWarning.check(source: .systemAudio, quietSeconds: 30, heardSound: false, othersPlayingSeconds: 0.5) == nil)
    }

    @Test("開始之後不到 6 秒不提醒，就算別的程式在出聲", arguments: [SilenceWarning.Source.microphone, .systemAudio])
    func nothingBeforeSixSeconds(source: SilenceWarning.Source) {
        #expect(SilenceWarning.check(source: source, quietSeconds: 5.75, heardSound: false, othersPlayingSeconds: 5) == nil)
    }

    @Test("麥克風：開始之後一直靜音 6 秒就提醒，不看別的程式有沒有在出聲")
    func microphoneWarnsAfterSixQuietSeconds() {
        #expect(SilenceWarning.check(source: .microphone, quietSeconds: 6, heardSound: false, othersPlayingSeconds: 0) == .microphone)
    }

    @Test("收到過聲音之後就不提醒：權限沒有問題，之後的安靜是正常的", arguments: [SilenceWarning.Source.microphone, .systemAudio, .file])
    func neverAfterHearingSound(source: SilenceWarning.Source) {
        #expect(SilenceWarning.check(source: source, quietSeconds: 600, heardSound: true, othersPlayingSeconds: 60) == nil)
    }

    @Test("音檔來源不提醒")
    func fileSourceNeverWarns() {
        #expect(SilenceWarning.check(source: .file, quietSeconds: 600, heardSound: false, othersPlayingSeconds: 60) == nil)
    }

    @Test("提醒的說明告訴使用者去哪裡處理：系統音訊是錄製系統音訊的權限，麥克風是選對、沒有靜音與麥克風的權限")
    func messagesSayWhatToDo() {
        let system = SilenceWarning.systemAudio.message
        #expect(system.contains("隱私權與安全性"))
        #expect(system.contains("錄製系統音訊"))
        let microphone = SilenceWarning.microphone.message
        #expect(microphone.contains("隱私權與安全性"))
        #expect(microphone.contains("麥克風"))
    }
}
