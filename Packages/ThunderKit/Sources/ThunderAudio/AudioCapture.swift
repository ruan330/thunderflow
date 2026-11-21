import CoreAudio
import Foundation

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
/// 一個可以收音的裝置。
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public var id: AudioDeviceID
    /// 裝置的固定識別字串：重開機、重新插上之後都一樣，用來記住使用者的選擇。
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var isDefault: Bool
}

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
    case deviceNotFound(String)
    case coreAudio(operation: String, status: OSStatus)
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .noInputDevice: "找不到可以收音的裝置"
        case .deviceNotFound(let uid): "找不到先前選擇的裝置（\(uid)）"
        case .coreAudio(let operation, let status): "\(operation) 失敗（Core Audio 錯誤 \(status)）"
        case .unreadableFile(let detail): "音檔讀不出來：\(detail)"
        }
    }
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] { [] }
}

public final class AudioCapture: @unchecked Sendable {
    public let source: CaptureSource
    public let mixer: CaptureMixer
    public var onEnded: (@Sendable () -> Void)?
    public private(set) var sourceDescription = ""

    public init(source: CaptureSource, ring: RingBuffer) {
        self.source = source
        mixer = CaptureMixer(ring: ring)
    }

    public func start() throws -> Double { 0 }
    public func stop() {}
}
