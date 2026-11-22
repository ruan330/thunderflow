import Foundation
import ThunderAudio
import ThunderCore

/// 錄音中要不要重新開始收音（DESIGN.md 2.3 節第 9 條、5.4 節、D26）。純函式，有測試。
///
/// App 在裝置有變化、或定期檢查時照這裡的判斷呼叫 `LiveRecording.resumeCapture(reason:)`，接著錄同一場。
/// 睡眠不在這裡：睡著之前 `suspendCapture()`，醒來之後直接接著錄。
public enum CaptureWatch {
    /// 一直沒有收到 callback 這麼久（秒），就當成收音停了。
    public static let stallSeconds = 3.0

    /// 判斷時要看的狀況。
    public struct Snapshot: Sendable {
        public var source: CaptureSource
        /// 收音用的裝置（`LiveRecording.captureDeviceUID`）：麥克風的 UID，或系統音訊開始時的預設輸出裝置的 UID。
        public var deviceInUse: String?
        /// 現在有的收音裝置的 UID。不知道時是 nil（不判斷裝置是不是不見了）。
        public var inputUIDs: [String]?
        /// 現在的預設輸出裝置的 UID。不知道時是 nil（不判斷輸出裝置是不是換了）。
        public var defaultOutputUID: String?
        /// 多久沒有收到 callback（秒）。
        public var secondsWithoutCallbacks: Double

        public init(
            source: CaptureSource, deviceInUse: String?, inputUIDs: [String]? = nil, defaultOutputUID: String? = nil,
            secondsWithoutCallbacks: Double = 0
        ) {
            self.source = source
            self.deviceInUse = deviceInUse
            self.inputUIDs = inputUIDs
            self.defaultOutputUID = defaultOutputUID
            self.secondsWithoutCallbacks = secondsWithoutCallbacks
        }
    }

    /// 要重新開始收音的原因（`deviceLost`、`outputChanged`、`captureStalled`）；不需要時是 nil。
    public static func reason(_ snapshot: Snapshot) -> GapReason? {
        switch snapshot.source {
        case .file:
            return nil
        case .microphone:
            if let device = snapshot.deviceInUse, let inputs = snapshot.inputUIDs, !inputs.contains(device) {
                return .deviceLost
            }
        case .systemAudio:
            if let device = snapshot.deviceInUse, let output = snapshot.defaultOutputUID, output != device {
                return .outputChanged
            }
        }
        return snapshot.secondsWithoutCallbacks >= stallSeconds ? .captureStalled : nil
    }
}
