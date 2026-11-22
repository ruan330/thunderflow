import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession

/// 錄音中什麼時候要重新開始收音（DESIGN.md 5.4 節、D26）：裝置不見、預設輸出換了、收音停了。
@Suite("錄音中要不要重新開始收音")
struct CaptureWatchTests {
    private let microphone = CaptureSource.microphone(deviceUID: "usb-mic")

    @Test("麥克風：用的裝置還在清單裡，不用重新開始")
    func microphoneStillThere() {
        let snapshot = CaptureWatch.Snapshot(source: microphone, deviceInUse: "usb-mic", inputUIDs: ["built-in", "usb-mic"])
        #expect(CaptureWatch.reason(snapshot) == nil)
    }

    @Test("麥克風：用的裝置不在清單裡了（拔掉 USB 麥克風、AirPods 斷線）：重新開始，原因是裝置不見了")
    func microphoneLost() {
        let snapshot = CaptureWatch.Snapshot(source: microphone, deviceInUse: "usb-mic", inputUIDs: ["built-in"])
        #expect(CaptureWatch.reason(snapshot) == .deviceLost)
        let nothingLeft = CaptureWatch.Snapshot(source: microphone, deviceInUse: "usb-mic", inputUIDs: [])
        #expect(CaptureWatch.reason(nothingLeft) == .deviceLost)
    }

    @Test("系統音訊：預設輸出裝置換了（接上或拔掉 AirPods）：重新開始，原因是換了輸出裝置")
    func systemAudioOutputChanged() {
        let snapshot = CaptureWatch.Snapshot(source: .systemAudio, deviceInUse: "speakers", defaultOutputUID: "airpods")
        #expect(CaptureWatch.reason(snapshot) == .outputChanged)
    }

    @Test("系統音訊：預設輸出沒變，或查不到預設輸出時，不用重新開始")
    func systemAudioUnchanged() {
        #expect(
            CaptureWatch.reason(CaptureWatch.Snapshot(source: .systemAudio, deviceInUse: "speakers", defaultOutputUID: "speakers"))
                == nil)
        #expect(CaptureWatch.reason(CaptureWatch.Snapshot(source: .systemAudio, deviceInUse: "speakers")) == nil)
    }

    @Test("超過 3 秒沒有收到任何 callback：重新開始，原因是收音停了；不到 3 秒不動")
    func stalledCapture() {
        #expect(
            CaptureWatch.reason(CaptureWatch.Snapshot(source: .systemAudio, deviceInUse: "speakers", secondsWithoutCallbacks: 3))
                == .captureStalled)
        #expect(
            CaptureWatch.reason(CaptureWatch.Snapshot(source: microphone, deviceInUse: "usb-mic", secondsWithoutCallbacks: 2.75))
                == nil)
    }

    @Test("裝置不見了，也就收不到 callback：原因記成裝置不見了")
    func deviceLostWinsOverStalled() {
        let snapshot = CaptureWatch.Snapshot(
            source: microphone, deviceInUse: "usb-mic", inputUIDs: ["built-in"], secondsWithoutCallbacks: 10)
        #expect(CaptureWatch.reason(snapshot) == .deviceLost)
    }

    @Test("音檔來源一律不重新開始（不經過裝置，也沒有 callback）")
    func fileSourceNeverRestarts() {
        let snapshot = CaptureWatch.Snapshot(
            source: .file(URL(fileURLWithPath: "/tmp/a.wav")), deviceInUse: nil, inputUIDs: [], secondsWithoutCallbacks: 60)
        #expect(CaptureWatch.reason(snapshot) == nil)
    }
}
