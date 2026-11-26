#if os(macOS)
import CoreAudio
import Foundation

/// 注意收音裝置的變化：接上或拔掉麥克風、AirPods 連上或斷開、系統預設的輸入或輸出裝置改變時，
/// 在背景重新列出裝置（`AudioDevices.inputDevices()`）並交給 `onChange`。
///
/// 不定時喚醒：只有裝置真的改變時，Core Audio 才在這個物件自己的佇列上通知。釋放時停止注意。
/// 這一層只做轉接，沒有判斷；接上與拔掉要在實機上試。
public final class AudioDeviceWatcher: @unchecked Sendable {
    // @unchecked Sendable：建立之後不再改變。listener 只交給 Core Audio，在 `queue` 上被呼叫。
    private let queue = DispatchQueue(label: "ThunderFlow.AudioDeviceWatcher", qos: .utility)
    private let listener: AudioObjectPropertyListenerBlock

    /// 會碰 Core Audio：不要在主執行緒上建立（程式第一次碰 Core Audio 要等它初始化，DESIGN.md 9.8 節）。
    /// - Parameter onChange: 裝置改變之後的裝置清單。在背景佇列上被呼叫。
    public init(onChange: @escaping @Sendable ([AudioInputDevice]) -> Void) {
        listener = { _, _ in onChange(AudioDevices.inputDevices()) }
        for var address in Self.addresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    deinit {
        for var address in Self.addresses {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    /// 裝置清單、系統預設的輸入裝置（清單裡「系統預設」的標記跟著它），以及預設的輸出裝置（錄系統音訊時要跟著換）。
    private static var addresses: [AudioObjectPropertyAddress] {
        [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            AudioObjectPropertyAddress(
                mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
    }
}
#endif
