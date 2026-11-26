#if os(iOS)
import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// iPhone 的收音（DESIGN.md 5.10 節，D36）：AVAudioSession（`record`）加上 RemoteIO 的 input callback。
///
/// 和 Mac 的 HAL IOProc 一樣，callback 在即時執行緒上只做 memcpy 進 RingBuffer（5.3 節）：
/// 不配置記憶體、不上鎖、不寫 log、不 `await`。轉成單聲道 Float32 由 RemoteIO 自己做（輸出格式設成單聲道）。
///
/// 固定用手機內建的麥克風：類別是 `record`、不加 `allowBluetooth`，戴著 AirPods 也不會改用耳機的麥克風
/// （音質差，收到的又是耳邊的聲音）。被來電或 Siri 打斷時 iOS 會停掉收音，由畫面呼叫
/// `LiveRecording.suspendCapture()`／`resumeCapture(reason: .interrupted)` 接著錄同一場。
public final class AudioCapture: @unchecked Sendable {
    // @unchecked Sendable：可變狀態只在 `start`、`stop` 裡使用（由呼叫端保證不同時呼叫）；
    // 即時執行緒只碰 `input`，它的可變部分是 atomic，或只在即時執行緒上使用。
    public let source: CaptureSource
    private let ring: RingBuffer
    private let input: InputState
    private var unit: AudioUnit?
    private var player: FilePlayer?
    /// 來源自己結束了（音檔播完）。在別的執行緒上被呼叫。
    public var onEnded: (@Sendable () -> Void)?

    /// 來源的說明，記在 `session.json`，也顯示在畫面上。
    public private(set) var sourceDescription = ""
    /// 收音用的輸入裝置（內建麥克風的 UID）。開始之後才有值。
    public private(set) var inputUID: String?

    public init(source: CaptureSource, ring: RingBuffer) {
        self.source = source
        self.ring = ring
        input = InputState(ring: ring)
    }

    deinit {
        stop()
    }

    /// 開始收音。回傳取樣率（寫進 RingBuffer 的是這個取樣率的單聲道樣本）。
    public func start() throws -> Double {
        switch source {
        case .file(let url):
            let player = try FilePlayer(url: url, ring: ring)
            player.onEnded = onEnded
            self.player = player
            sourceDescription = "音檔：\(url.lastPathComponent)"
            player.start()
            return player.sampleRate
        case .systemAudio:
            throw AudioCaptureError.unsupported("iPhone 不能錄其他 App 的聲音，請改用麥克風。")
        case .microphone:
            return try startMicrophone()
        }
    }

    /// 停止收音。返回之後不會再寫入 RingBuffer。可以重複呼叫。
    public func stop() {
        player?.stop()
        player = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            input.unit = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: 麥克風

    private func startMicrophone() throws -> Double {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            throw AudioCaptureError.coreAudio(operation: "啟用錄音的音訊工作階段", status: OSStatus((error as NSError).code))
        }
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        guard session.isInputAvailable else { throw AudioCaptureError.noInputDevice }
        let rate = session.sampleRate
        inputUID = session.currentRoute.inputs.first?.uid
        sourceDescription = "iPhone 麥克風"

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioCaptureError.noInputDevice }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "建立收音元件")
        guard let unit = created else { throw AudioCaptureError.noInputDevice }
        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize),
                "打開收音")
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize),
                "關掉播放")
            var format = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
                mReserved: 0)
            try check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                "設定收音格式")
            var maximumFrames = UInt32(InputState.capacity)
            try check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, flagSize),
                "設定每次的樣本數")
            var callback = AURenderCallbackStruct(
                inputProc: phoneInputCallback, inputProcRefCon: Unmanaged.passUnretained(input).toOpaque())
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "設定收音的 callback")
            input.prepare(unit: unit)
            try check(AudioUnitInitialize(unit), "初始化收音元件")
            try check(AudioOutputUnitStart(unit), "開始收音")
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            input.unit = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.unit = unit
        return rate
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioCaptureError.coreAudio(operation: operation, status: status) }
    }
}

extension AudioCapture: AudioCapturing {
    public var notice: String? { nil }
    public var deviceUID: String? { inputUID }
    public var callbackCount: Int { input.callbacks.load(ordering: .relaxed) }
    public var discontinuityCount: Int { input.discontinuities.load(ordering: .relaxed) }
    public var firstSampleUptimeNanoseconds: UInt64? {
        let value = input.firstUptime.load(ordering: .relaxed)
        return value == 0 ? nil : value
    }
}

/// RemoteIO 的 input callback 用到的東西。記憶體在開始之前配置好，callback 裡只用、不配置。
final class InputState: @unchecked Sendable {
    // @unchecked Sendable：`unit` 在開始之前設定、停止之後清掉（callback 不會同時執行）；
    // `expected`、`hasExpected` 只在即時執行緒上使用；計數是 atomic。
    /// 一次最多收幾個樣本（RemoteIO 每次通常是 1024 個以下）。
    static let capacity = 4096

    var unit: AudioUnit?
    let ring: RingBuffer
    let samples: UnsafeMutablePointer<Float>
    let buffers: UnsafeMutableAudioBufferListPointer
    let callbacks = Atomic<Int>(0)
    let discontinuities = Atomic<Int>(0)
    let firstUptime = Atomic<UInt64>(0)
    var expected: Double = 0
    var hasExpected = false

    init(ring: RingBuffer) {
        self.ring = ring
        samples = .allocate(capacity: Self.capacity)
        samples.initialize(repeating: 0, count: Self.capacity)
        buffers = AudioBufferList.allocate(maximumBuffers: 1)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(Self.capacity * MemoryLayout<Float>.size), mData: samples)
    }

    deinit {
        samples.deallocate()
        free(buffers.unsafeMutablePointer)
    }

    func prepare(unit: AudioUnit) {
        self.unit = unit
        hasExpected = false
    }

    /// 在即時執行緒上：把這一次的樣本拿出來，memcpy 進 RingBuffer。
    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32, _ frames: UInt32
    ) -> OSStatus {
        guard let unit, Int(frames) <= Self.capacity else { return noErr }
        buffers[0].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        buffers[0].mData = UnsafeMutableRawPointer(samples)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffers.unsafeMutablePointer)
        guard status == noErr else { return status }
        let sampleTime = timeStamp.pointee.mSampleTime
        if hasExpected, abs(sampleTime - expected) > 0.5 { discontinuities.add(1, ordering: .relaxed) }
        expected = sampleTime + Double(frames)
        hasExpected = true
        if firstUptime.load(ordering: .relaxed) == 0 {
            firstUptime.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        }
        callbacks.add(1, ordering: .relaxed)
        _ = ring.write(UnsafeBufferPointer(start: samples, count: Int(frames)))
        return noErr
    }
}

/// RemoteIO 的 input callback（C 函式，不能帶 context：用 refCon 找回 `InputState`）。
private let phoneInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<InputState>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
}
#endif
