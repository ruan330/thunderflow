import Foundation

/// 收音的來源。
public enum CaptureSource: Sendable, Equatable {
    /// 麥克風。`deviceUID` 是 nil 時用系統預設的輸入裝置。
    case microphone(deviceUID: String?)
    /// 系統音訊：所有 App 的聲音，不包含 ThunderFlow 自己。
    case systemAudio
    /// 把音檔當成來源，以即時速度播放（不出聲）。用來測試，不需要麥克風。
    case file(URL)
}

public enum AudioCaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case coreAudio(operation: String, status: OSStatus)
    /// 系統音訊的裝置建立了，卻沒辦法開始收音。實機上看到的原因：還沒有允許「錄製系統音訊」
    /// （第一次使用、或開發版重新打包之後）。macOS 跳出授權視窗的同時，開始收音就直接失敗，不會等使用者回答。
    case systemAudioNotStarted(status: OSStatus)
    case unreadableFile(String)
    /// 這台裝置做不到（例如 iPhone 不能錄其他 App 的聲音）。
    case unsupported(String)

    public var description: String {
        switch self {
        case .noInputDevice: "找不到可以收音的裝置"
        case .coreAudio(let operation, let status): "\(operation) 失敗（Core Audio 錯誤 \(status)）"
        case .systemAudioNotStarted(let status):
            "系統音訊沒辦法開始（Core Audio 錯誤 \(status)），通常是還沒有允許 ThunderFlow 錄製系統音訊。"
                + "第一次使用時 macOS 會跳出授權視窗：請按「允許」，然後再按一次開始。"
                + "沒有看到視窗的話，請到「系統設定 → 隱私權與安全性」，在錄製系統音訊的項目裡允許 ThunderFlow。"
        case .unreadableFile(let detail): "音檔讀不出來：\(detail)"
        case .unsupported(let detail): detail
        }
    }
}

/// 收音的來源：真正的裝置（`AudioCapture`），或測試用的假來源。
///
/// 錄音中途可以換掉（`LiveRecording.resumeCapture`）：裝置不見、睡眠醒來、換了輸出裝置時，建立新的來源接著錄同一場。
public protocol AudioCapturing: AnyObject, Sendable {
    /// 開始收音，把單聲道樣本寫進建立時給的 RingBuffer。回傳取樣率。
    func start() throws -> Double
    /// 停止收音。返回之後不會再寫入 RingBuffer。可以重複呼叫。
    func stop()
    /// 來源的說明（裝置名稱或「系統音訊」）。開始之後才有值。
    var sourceDescription: String { get }
    /// 和使用者選的不一樣時給使用者的說明（記住的麥克風不在了，改用系統預設的）。開始之後才有值。
    var notice: String? { get }
    /// 收音用的裝置：麥克風是它的 UID，系統音訊是開始時的預設輸出裝置的 UID，音檔是 nil。
    /// 用來判斷裝置是不是不見了、預設輸出是不是換了。開始之後才有值。
    var deviceUID: String? { get }
    /// 裝置的 callback 被呼叫了幾次。一直沒有增加，代表收音停了。音檔來源一直是 0。
    var callbackCount: Int { get }
    /// 裝置回報樣本位置不連續的次數。
    var discontinuityCount: Int { get }
    /// 裝置第一次送來樣本的時間（`CLOCK_UPTIME_RAW` 的奈秒）。音檔來源一直是 nil。
    var firstSampleUptimeNanoseconds: UInt64? { get }
    /// 來源自己結束了（音檔播完）。在別的執行緒上被呼叫。要在 `start()` 之前設定。
    var onEnded: (@Sendable () -> Void)? { get set }
}
