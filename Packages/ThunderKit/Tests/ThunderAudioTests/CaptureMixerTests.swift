import CoreAudio
import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

/// 做出一份裝置會給的樣本（`AudioBufferList`），測試結束時釋放。
private final class DeviceBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// - Parameter channels: 每個 buffer 的聲道數。`[2]` 是交錯的立體聲，`[1, 1]` 是不交錯的立體聲。
    init(channels: [Int], frames: Int, value: (_ frame: Int, _ channel: Int) -> Float) {
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var channelBase = 0
        for (index, count) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
            for frame in 0..<frames {
                for channel in 0..<count { data[frame * count + channel] = value(frame, channelBase + channel) }
            }
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(count), mDataByteSize: UInt32(frames * count * MemoryLayout<Float>.size), mData: data)
            channelBase += count
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafePointer<AudioBufferList> { UnsafePointer(list.unsafePointer) }
}

private func drain(_ ring: RingBuffer) -> [Float] {
    var output = [Float](repeating: 0, count: ring.availableToRead)
    let count = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    return Array(output.prefix(count))
}

@Suite("擷取外殼：音訊 callback 只把樣本寫進 RingBuffer")
struct CaptureMixerTests {
    @Test("單聲道：樣本原樣寫進去，一個不少、順序不亂")
    func mono() {
        let ring = RingBuffer(minimumCapacity: 4_096)
        let mixer = CaptureMixer(ring: ring)
        for call in 0..<4 {
            let buffers = DeviceBuffers(channels: [1], frames: 480) { frame, _ in Float(call * 480 + frame) }
            mixer.process(buffers.pointer, sampleTime: Double(call * 480))
        }
        #expect(Signal.firstMismatch(in: drain(ring), sequenceFrom: 0) == nil)
        #expect(mixer.callbackCount == 4)
        #expect(mixer.discontinuityCount == 0)
        #expect(ring.droppedSampleCount == 0)
    }

    @Test("立體聲：兩個聲道平均成單聲道，交錯與不交錯的排法結果相同", arguments: [[2], [1, 1]])
    func stereo(layout: [Int]) {
        let ring = RingBuffer(minimumCapacity: 1_024)
        let mixer = CaptureMixer(ring: ring)
        // 左聲道是 0.5，右聲道是每個樣本的序號 ÷ 1000
        let buffers = DeviceBuffers(channels: layout, frames: 100) { frame, channel in channel == 0 ? 0.5 : Float(frame) / 1_000 }
        mixer.process(buffers.pointer, sampleTime: nil)

        let mixed = drain(ring)
        #expect(mixed.count == 100)
        for (frame, sample) in mixed.enumerated() {
            #expect(abs(sample - (0.5 + Float(frame) / 1_000) / 2) < 1e-6)
        }
    }

    @Test("樣本位置：連續的不計數；中間掉了一段計一次；裝置沒有給位置就不檢查")
    func discontinuities() {
        let ring = RingBuffer(minimumCapacity: 8_192)
        let mixer = CaptureMixer(ring: ring)
        let buffers = DeviceBuffers(channels: [1], frames: 480) { _, _ in 0.1 }

        mixer.process(buffers.pointer, sampleTime: 1_000)
        mixer.process(buffers.pointer, sampleTime: 1_480)
        mixer.process(buffers.pointer, sampleTime: 1_960)
        #expect(mixer.discontinuityCount == 0)

        mixer.process(buffers.pointer, sampleTime: 2_920)  // 應該是 2,440：掉了 480 個樣本
        #expect(mixer.discontinuityCount == 1)
        mixer.process(buffers.pointer, sampleTime: 3_400)
        #expect(mixer.discontinuityCount == 1)

        mixer.process(buffers.pointer, sampleTime: nil)
        mixer.process(buffers.pointer, sampleTime: nil)
        #expect(mixer.discontinuityCount == 1)

        // 重新開始擷取之後，第一次不和之前的位置比
        mixer.resetContinuity()
        mixer.process(buffers.pointer, sampleTime: 90_000)
        #expect(mixer.discontinuityCount == 1)
        #expect(mixer.callbackCount == 8)
    }

    @Test("一次送來的樣本超過暫存區：只寫入放得下的部分，並且計數", arguments: [[1], [2]])
    func oversized(layout: [Int]) {
        let ring = RingBuffer(minimumCapacity: 1_024)
        let mixer = CaptureMixer(ring: ring, maximumFrames: 64)
        let buffers = DeviceBuffers(channels: layout, frames: 100) { _, _ in 0.25 }
        mixer.process(buffers.pointer, sampleTime: nil)
        #expect(drain(ring).count == 64)
        #expect(mixer.oversizedCallbackCount == 1)
    }

    @Test("從不是主執行緒的地方呼叫：不會出錯，樣本一個不少")
    func offMainThread() {
        let ring = RingBuffer(minimumCapacity: 1 << 20)
        let mixer = CaptureMixer(ring: ring)
        let finished = completesWithin(.seconds(5)) {
            precondition(!Thread.isMainThread)
            for call in 0..<1_000 {
                let buffers = DeviceBuffers(channels: [1], frames: 480) { frame, _ in Float(call * 480 + frame) }
                mixer.process(buffers.pointer, sampleTime: Double(call * 480))
            }
        }
        #expect(finished)
        #expect(mixer.callbackCount == 1_000)
        #expect(mixer.discontinuityCount == 0)
        #expect(Signal.firstMismatch(in: drain(ring), sequenceFrom: 0) == nil)
        #expect(ring.availableToRead == 0)
    }

    @Test("沒有樣本的 callback：什麼都不寫")
    func empty() {
        let ring = RingBuffer(minimumCapacity: 64)
        let mixer = CaptureMixer(ring: ring)
        let buffers = DeviceBuffers(channels: [1], frames: 0) { _, _ in 0 }
        mixer.process(buffers.pointer, sampleTime: 0)
        #expect(ring.availableToRead == 0)
        #expect(mixer.callbackCount == 1)
    }
}

@Suite("音檔來源：把音檔當成麥克風")
struct FileSourceTests {
    @Test("以即時速度把音檔的樣本寫進 RingBuffer，播完會通知")
    func playsFile() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        // 用錄音元件寫一個 0.5 秒的音檔
        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: 16_000)
        let samples = Signal.sine(frequency: 440, sampleRate: 16_000, duration: 0.5)
        try samples.withUnsafeBufferPointer { try recorder.append($0) }
        try recorder.close()
        let segment = try #require(try RecordingFiles.segments(in: tmp.url).first)

        let ring = RingBuffer(minimumCapacity: 16_000)
        let capture = AudioCapture(source: .file(segment.url), ring: ring)
        let ended = LockedValue(false)
        capture.onEnded = { ended.withValue { $0 = true } }
        let started = ContinuousClock.now
        let rate = try capture.start()
        #expect(rate == 16_000)
        let finished = await waitUntil(timeout: .seconds(5), { ended.value })
        let elapsed = ContinuousClock.now - started
        capture.stop()

        #expect(finished)
        #expect(ring.availableToRead == 8_000)
        #expect(elapsed > .milliseconds(400), "要照音檔的時間走，不是一口氣倒完")
        #expect(capture.sourceDescription.contains(segment.url.lastPathComponent))
        let played = drain(ring)
        #expect(abs(Signal.rms(played) - Signal.rms(samples)) < 50)
    }

    @Test("讀不出來的檔案：開始時就丟出錯誤")
    func unreadable() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let bogus = tmp.url.appendingPathComponent("not-audio.wav")
        try Data("hello".utf8).write(to: bogus)
        let capture = AudioCapture(source: .file(bogus), ring: RingBuffer(minimumCapacity: 64))
        #expect(throws: AudioCaptureError.self) { _ = try capture.start() }
    }
}

@Suite("音訊裝置清單")
struct AudioDevicesTests {
    @Test("查詢輸入裝置不會出錯；每個裝置都有識別字串、名稱與聲道數，預設裝置最多一個")
    func listsDevices() {
        // CI 的機器可能沒有任何輸入裝置，所以只檢查列出來的內容合不合理
        let devices = AudioDevices.inputDevices()
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(device.channels > 0)
        }
        #expect(devices.filter(\.isDefault).count <= 1)
        #expect(Set(devices.map(\.uid)).count == devices.count)
    }
}
