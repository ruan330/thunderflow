import CoreAudio
import Foundation
import Testing
import ThunderAudio

/// 系統音訊用的 aggregate device 的組成（DESIGN.md 5.4 節）。
///
/// 真正的擷取需要實機與「錄製系統音訊」的權限，用 App 的自我檢查（`-diagnoseCapture YES`）在實機上確認；
/// 這裡確認組成本身，避免日後又照著範例程式把「等到有 App 出聲才開始」加回去。
@Suite("系統音訊：aggregate device 的組成")
struct SystemAudioDeviceTests {
    private let tap = UUID()
    private var composition: [String: Any] { SystemAudioDevice.composition(outputUID: "BuiltInSpeakerDevice", tapUID: tap) }

    @Test("一開始就收音，不等到有 App 出聲：沒有播放時收到靜音，錄音長度等於實際經過的時間")
    func startsWithoutWaitingForAudio() {
        // 設了 TapAutoStart 的話，開始時沒有 App 出聲，裝置就一直不啟動；播放暫停的時段也收不到樣本，
        // 錄音比實際經過的時間短（2026-11-21 實機確認：一場經過 137 秒只錄到 59 秒）
        let autoStart = composition[kAudioAggregateDeviceTapAutoStartKey] as? Bool ?? false
        #expect(!autoStart)
    }

    @Test("私有的裝置：主裝置與唯一的子裝置是預設輸出裝置，擷取點開啟時脈補償")
    func privateDeviceAroundTheTap() throws {
        #expect(composition[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(composition[kAudioAggregateDeviceMainSubDeviceKey] as? String == "BuiltInSpeakerDevice")
        let subDevices = try #require(composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.map { $0[kAudioSubDeviceUIDKey] as? String } == ["BuiltInSpeakerDevice"])
        let taps = try #require(composition[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps.first?[kAudioSubTapUIDKey] as? String == tap.uuidString)
        #expect(taps.first?[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }
}

/// 系統音訊沒辦法開始時給使用者的說明。真正的失敗需要實機（還沒有允許「錄製系統音訊」的 App），
/// 這裡確認說明本身。
@Suite("系統音訊：沒辦法開始時的說明")
struct SystemAudioNotStartedTests {
    @Test("系統音訊沒辦法開始時，說明告訴使用者在授權視窗按「允許」，再按一次開始")
    func notStartedExplainsPermission() {
        // 實機：還沒有允許時，macOS 跳出授權視窗，開始收音同時就失敗（Core Audio 錯誤 268451843）
        let message = AudioCaptureError.systemAudioNotStarted(status: 268_451_843).description
        #expect(message.contains("268451843"))
        #expect(message.contains("允許"))
        #expect(message.contains("再按一次開始"))
    }
}
