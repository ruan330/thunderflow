import AVFoundation
import CoreAudio
import Foundation

/// 一個可以收音的裝置。
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public var id: AudioDeviceID
    /// 裝置的固定識別字串：重開機、重新插上之後都一樣，用來記住使用者的選擇。
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var isDefault: Bool

    public init(id: AudioDeviceID, uid: String, name: String, sampleRate: Double, channels: Int, isDefault: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
        self.isDefault = isDefault
    }
}

/// 開始收音時選定的麥克風（DESIGN.md 5.4 節）。選法是純函式，不碰 Core Audio，有測試。
public struct MicrophoneChoice: Sendable, Equatable {
    /// 要用的裝置。
    public var device: AudioInputDevice
    /// 指定的裝置找不到、改用系統預設的輸入裝置時，是原本指定的 UID；其他時候是 nil。
    public var missingUID: String?

    public init(device: AudioInputDevice, missingUID: String? = nil) {
        self.device = device
        self.missingUID = missingUID
    }

    /// 依指定的 UID 從裝置清單選出要用的裝置：
    /// - 沒有指定（nil 或空字串）：系統預設的輸入裝置；清單裡沒有標記為預設的，就用第一個。
    /// - 指定的還在：用它。
    /// - 指定的不在了（拔掉、iPhone 拿起來解鎖）：改用系統預設的輸入裝置照樣開始，記下原本指定的 UID。
    /// - 一個可以收音的裝置都沒有：nil。
    public static func choose(uid: String?, from devices: [AudioInputDevice]) -> MicrophoneChoice? {
        guard let fallback = devices.first(where: \.isDefault) ?? devices.first else { return nil }
        guard let uid, !uid.isEmpty else { return MicrophoneChoice(device: fallback) }
        if let chosen = devices.first(where: { $0.uid == uid }) { return MicrophoneChoice(device: chosen) }
        return MicrophoneChoice(device: fallback, missingUID: uid)
    }

    /// 改用了別的裝置時給使用者的說明：說這一場用了哪一個裝置。照指定的（或本來就用預設的）時是 nil。
    public var notice: String? {
        guard missingUID != nil else { return nil }
        return "先前選擇的麥克風找不到（可能被拔掉了），這一場改用「\(device.name)」錄音。原本的麥克風接回來之後，下一場會再用它。"
    }
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
    case coreAudio(operation: String, status: OSStatus)
    /// 系統音訊的裝置建立了，卻沒辦法開始收音。實機上看到的原因：還沒有允許「錄製系統音訊」
    /// （第一次使用、或開發版重新打包之後）。macOS 跳出授權視窗的同時，開始收音就直接失敗，不會等使用者回答。
    case systemAudioNotStarted(status: OSStatus)
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .noInputDevice: "找不到可以收音的裝置"
        case .coreAudio(let operation, let status): "\(operation) 失敗（Core Audio 錯誤 \(status)）"
        case .systemAudioNotStarted(let status):
            "系統音訊沒辦法開始（Core Audio 錯誤 \(status)），通常是還沒有允許 ThunderFlow 錄製系統音訊。"
                + "第一次使用時 macOS 會跳出授權視窗：請按「允許」，然後再按一次開始。"
                + "沒有看到視窗的話，請到「系統設定 → 隱私權與安全性」，在錄製系統音訊的項目裡允許 ThunderFlow。"
        case .unreadableFile(let detail): "音檔讀不出來：\(detail)"
        }
    }
}

/// 查詢音訊裝置。裝置清單每次都重新向系統查詢，不寫死任何裝置名稱。
public enum AudioDevices {
    /// 所有有輸入聲道的裝置。不含這個程式自己建立的私有 aggregate device（錄系統音訊用的，它也有輸入聲道）。
    public static func inputDevices() -> [AudioInputDevice] {
        let defaultID = defaultDevice(input: true)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            let channels = inputChannelCount(of: id)
            guard channels > 0, !isPrivateAggregate(id), let uid = string(kAudioDevicePropertyDeviceUID, of: id) else {
                return nil
            }
            return AudioInputDevice(
                id: id, uid: uid, name: string(kAudioObjectPropertyName, of: id) ?? uid,
                sampleRate: nominalSampleRate(of: id), channels: channels, isDefault: id == defaultID)
        }
    }

    /// 除了這個程式以外，有沒有程式正在送聲音給輸出裝置（`kAudioProcessPropertyIsRunningOutput`，送的可能是靜音）。
    /// 不需要任何權限。查不到時回傳 nil。
    ///
    /// 每個有音訊的程式都要問一次（實測 38 個程式約 6–8 ms）：不要在主執行緒上呼叫，也不要頻繁呼叫。
    public static func isAnotherProcessPlaying() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        // 錄系統音訊時，自己的 IOProc 也算在送聲音（交回去的是靜音）：用 PID 排除自己
        let ownPID = getpid()
        return processes.contains { process in
            value(kAudioProcessPropertyIsRunningOutput, of: process, as: UInt32.self) == 1
                && value(kAudioProcessPropertyPID, of: process, as: pid_t.self) != ownPID
        }
    }

    /// 讀一個固定大小的屬性。讀不到時回傳 nil。
    static func value<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID, as type: Value.Type
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr,
            size == MemoryLayout<Value>.size
        else { return nil }
        return raw.load(as: Value.self)
    }

    /// 系統預設的輸入或輸出裝置。
    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func nominalSampleRate(of device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    /// 私有的 aggregate device 只有建立它的程式看得到，所以一定是自己錄系統音訊用的那一個。
    /// 裝置有變化時清單會重新列出（`AudioDeviceWatcher`），錄系統音訊時它不該出現在麥克風的選單裡。
    static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return false }
        let composition = value.takeRetainedValue() as? [String: Any] ?? [:]
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// 系統音訊用的私有 aggregate device 的組成（DESIGN.md 5.4 節）：預設輸出裝置加上一個擷取點。
///
/// 抽出來成為純函式，組成可以直接測試；真正的擷取需要實機與權限，用 App 的自我檢查確認。
public enum SystemAudioDevice {
    /// - Parameters:
    ///   - outputUID: 預設輸出裝置的 UID。它是主裝置，aggregate device 的時脈跟著它走。
    ///   - tapUID: 擷取點的 UUID（`CATapDescription.uuid`）。
    ///   - aggregateUID: aggregate device 自己的 UID，每次建立都用新的。
    public static func composition(outputUID: String, tapUID: UUID, aggregateUID: UUID = UUID()) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "ThunderFlow 系統音訊",
            kAudioAggregateDeviceUIDKey: aggregateUID.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // 不等到有 App 出聲：等的話，開始時沒有播放，裝置就一直不啟動（也不回報錯誤）；
            // 播放暫停的時段也收不到樣本，錄音會比實際經過的時間短。不等的話，沒有播放時收到的是靜音。
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID.uuidString]
            ],
        ]
    }
}

/// 收音：把來源的聲音以單聲道寫進 RingBuffer。麥克風與系統音訊都走 HAL 的 IOProc（DESIGN.md 5.4 節）。
///
/// 這一層只做轉接，不放判斷：真正在即時執行緒上執行的是 `CaptureMixer`。
/// `start`、`stop` 由同一條執行緒（主執行緒）呼叫。
public final class AudioCapture: @unchecked Sendable {
    // @unchecked Sendable：可變狀態只在 `start`、`stop` 裡使用（由呼叫端保證不同時呼叫）；
    // 即時執行緒只碰 `mixer`，它本身可以跨執行緒使用。
    public let source: CaptureSource
    public let mixer: CaptureMixer
    private let ring: RingBuffer

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var player: FilePlayer?
    /// 來源自己結束了（音檔播完）。在別的執行緒上被呼叫。
    public var onEnded: (@Sendable () -> Void)?

    public init(source: CaptureSource, ring: RingBuffer) {
        self.source = source
        self.ring = ring
        mixer = CaptureMixer(ring: ring)
    }

    deinit {
        stop()
    }

    /// 來源的說明，記在 `session.json`，也顯示在畫面上。
    public private(set) var sourceDescription = ""

    /// 麥克風：開始時選定的裝置。記住的裝置不在了會改用系統預設的，這時 `notice` 說明用了哪一個。開始之後才有值。
    public private(set) var microphoneChoice: MicrophoneChoice?

    /// 開始收音。回傳來源的取樣率（寫進 RingBuffer 的是這個取樣率的單聲道樣本）。
    public func start() throws -> Double {
        mixer.resetContinuity()
        switch source {
        case .microphone(let uid):
            return try startMicrophone(uid: uid)
        case .systemAudio:
            return try startSystemAudio()
        case .file(let url):
            let player = try FilePlayer(url: url, ring: ring)
            player.onEnded = onEnded
            self.player = player
            sourceDescription = "音檔：\(url.lastPathComponent)"
            player.start()
            return player.sampleRate
        }
    }

    /// 停止收音。可以重複呼叫。
    public func stop() {
        player?.stop()
        player = nil
        if let procID {
            let target = aggregateID != kAudioObjectUnknown ? aggregateID : device
            AudioDeviceStop(target, procID)
            AudioDeviceDestroyIOProcID(target, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: 麥克風

    /// 記住的裝置不在了（拔掉、iPhone 拿起來解鎖）就改用系統預設的輸入裝置照樣開始（`MicrophoneChoice`）。
    private func startMicrophone(uid: String?) throws -> Double {
        guard let choice = MicrophoneChoice.choose(uid: uid, from: AudioDevices.inputDevices()) else {
            throw AudioCaptureError.noInputDevice
        }
        microphoneChoice = choice
        device = choice.device.id
        sourceDescription = choice.device.name
        try startIOProc(on: choice.device.id)
        return choice.device.sampleRate
    }

    // MARK: 系統音訊（Process Tap＋私有的 aggregate device）

    private func startSystemAudio() throws -> Double {
        guard let output = AudioDevices.defaultDevice(input: false),
            let outputUID = AudioDevices.string(kAudioDevicePropertyDeviceUID, of: output)
        else { throw AudioCaptureError.noInputDevice }

        // 擷取所有 App 的聲音，但排除自己（這個 process 有發出過聲音時才查得到它的音訊物件）
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "ThunderFlow"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "建立系統音訊的擷取點")
        tapID = tap

        let aggregate = SystemAudioDevice.composition(outputUID: outputUID, tapUID: description.uuid)
        var created = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &created), "建立系統音訊的裝置")
            aggregateID = created
            sourceDescription = "系統音訊"
            try startIOProc(on: created) { .systemAudioNotStarted(status: $0) }
        } catch {
            stop()
            throw error
        }
        return tapSampleRate(tap) ?? AudioDevices.nominalSampleRate(of: output)
    }

    private func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func tapSampleRate(_ tap: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 else {
            return nil
        }
        return format.mSampleRate
    }

    // MARK: IOProc

    /// - Parameter startFailed: 裝置沒辦法開始收音時要丟出的錯誤（系統音訊要換成有說明的錯誤）。
    private func startIOProc(
        on target: AudioDeviceID,
        startFailed: (OSStatus) -> AudioCaptureError = { .coreAudio(operation: "開始收音", status: $0) }
    ) throws {
        let mixer = mixer
        var created: AudioDeviceIOProcID?
        // 不給 dispatch queue：block 直接在裝置的即時 IO 執行緒上被呼叫。裡面只呼叫 `CaptureMixer.process`。
        let status = AudioDeviceCreateIOProcIDWithBlock(&created, target, nil) { _, input, inputTime, output, _ in
            let time = inputTime.pointee
            let valid = time.mFlags.contains(.sampleTimeValid)
            mixer.process(input, sampleTime: valid ? time.mSampleTime : nil)
            // 這個裝置如果也有輸出，交回去的必須是靜音
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        try check(status, "建立音訊 callback")
        procID = created
        let started = AudioDeviceStart(target, created)
        if started != noErr {
            if let created { AudioDeviceDestroyIOProcID(target, created) }
            procID = nil
            throw startFailed(started)
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioCaptureError.coreAudio(operation: operation, status: status) }
    }
}

/// 把音檔當成來源：用一條專用執行緒，以即時速度把樣本寫進 RingBuffer。
final class FilePlayer: @unchecked Sendable {
    // @unchecked Sendable：`stopped` 由鎖保護；`file`、`buffer` 只在播放的那一條執行緒上使用。
    let sampleRate: Double
    var onEnded: (@Sendable () -> Void)?
    private let file: AVAudioFile
    private let ring: RingBuffer
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, ring: RingBuffer) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioCaptureError.unreadableFile(error.localizedDescription)
        }
        sampleRate = file.processingFormat.sampleRate
        self.ring = ring
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "ThunderFlow.FilePlayer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        let format = file.processingFormat
        let framesPerTick = AVAudioFrameCount(max(1, Int(sampleRate / 100)))  // 10 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerTick) else { return }
        var mono = [Float](repeating: 0, count: Int(framesPerTick))
        let started = ContinuousClock.now
        var played = 0
        while !isStopped {
            do { try file.read(into: buffer, frameCount: framesPerTick) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for index in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][index] }
                mono[index] = sum / Float(channelCount)
            }
            _ = mono.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
            played += frames
            // 照音檔的時間走：播到哪裡，就等到那個時間
            let due = started + .seconds(Double(played) / sampleRate)
            let wait = due - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) * 1e-18) }
        }
        if !isStopped { onEnded?() }
    }
}
