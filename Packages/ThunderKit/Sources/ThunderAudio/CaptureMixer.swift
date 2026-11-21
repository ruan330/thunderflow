import CoreAudio
import Foundation
import Synchronization

/// 音訊裝置的 callback 實際做的事：把裝置給的樣本混成單聲道，寫進 RingBuffer，並更新完整性計數。
///
/// 這個型別不屬於任何 actor，只接觸 RingBuffer 與 atomic 計數，所以可以在即時執行緒上使用
/// （DESIGN.md 5.3 節）：`process` 不配置記憶體、不上鎖、不寫 log、不等待。混音用的暫存區在建立時就配置好。
///
/// 裝置給的格式是 32-bit 浮點數；可以是交錯的（一個 buffer 裡有好幾個聲道），
/// 也可以是不交錯的（每個聲道一個 buffer）。兩種都把所有聲道平均成單聲道。
public final class CaptureMixer: @unchecked Sendable {
    // @unchecked Sendable：`scratch` 只在 `process` 裡使用，而 `process` 只會由裝置的那一條 IO 執行緒呼叫；
    // 其餘的狀態都是 Atomic 或建立後不再改變的常數。
    private let ring: RingBuffer
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let callbacks = Atomic<Int>(0)
    private let discontinuities = Atomic<Int>(0)
    private let oversized = Atomic<Int>(0)
    /// 第一次收到樣本的時間；0 代表還沒收到。
    private let firstFrames = Atomic<UInt64>(0)
    /// 下一次 callback 預期的樣本位置的位元表示；還沒收到過任何 callback 時是「沒有」。
    private let expectedSampleTime = Atomic<UInt64>(CaptureMixer.none)
    private static let none = UInt64.max

    /// - Parameter maximumFrames: 一次 callback 最多處理幾個樣本（每聲道）。超過的部分會被丟掉並計數。
    public init(ring: RingBuffer, maximumFrames: Int = 16_384) {
        self.ring = ring
        scratch = .allocate(capacity: max(1, maximumFrames))
        scratch.initialize(repeating: 0)
    }

    deinit {
        scratch.deallocate()
    }

    /// 到目前為止被呼叫了幾次。停止前後用來確認裝置真的有在送聲音。
    public var callbackCount: Int { callbacks.load(ordering: .relaxed) }

    /// 樣本位置不連續的次數：這一次的位置不等於上一次的位置加上一次的樣本數，代表中間掉了聲音。
    public var discontinuityCount: Int { discontinuities.load(ordering: .relaxed) }

    /// 一次送來的樣本超過暫存區大小的次數（超過的部分被丟掉了）。
    public var oversizedCallbackCount: Int { oversized.load(ordering: .relaxed) }

    /// 第一次收到樣本的時間（`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` 的奈秒）。還沒收到時是 nil。
    /// 用來量「按下開始到第一個樣本進來」（DESIGN.md 9.8 節的 `session.startToCapture`）。
    public var firstFramesUptimeNanoseconds: UInt64? {
        let value = firstFrames.load(ordering: .relaxed)
        return value == 0 ? nil : value
    }

    /// 處理裝置給的一批樣本。只能由裝置的 IO 執行緒呼叫。
    ///
    /// - Parameters:
    ///   - buffers: 裝置給的樣本（32-bit 浮點數）。
    ///   - sampleTime: 這一批第一個樣本的位置；裝置沒有提供時給 nil，就不檢查連續性。
    public func process(_ buffers: UnsafePointer<AudioBufferList>, sampleTime: Double?) {
        callbacks.add(1, ordering: .relaxed)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))

        // 每聲道的樣本數，以及全部的聲道數
        var frames = 0
        var channelCount = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mData != nil else { continue }
            let count = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            frames = frames == 0 ? count : min(frames, count)
            channelCount += channels
        }
        guard frames > 0, channelCount > 0 else { return }
        // 讀時鐘只是讀共用記憶體，不呼叫系統、不上鎖，可以在即時執行緒上做
        if firstFrames.load(ordering: .relaxed) == 0 {
            firstFrames.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        }

        if let sampleTime {
            let expected = expectedSampleTime.load(ordering: .relaxed)
            if expected != Self.none, abs(Double(bitPattern: expected) - sampleTime) >= 1 {
                discontinuities.add(1, ordering: .relaxed)
            }
            expectedSampleTime.store((sampleTime + Double(frames)).bitPattern, ordering: .relaxed)
        }

        if frames > scratch.count {
            oversized.add(1, ordering: .relaxed)
            frames = scratch.count
        }
        let output = scratch.baseAddress!

        // 單聲道、單一 buffer：最常見的麥克風，直接寫進去
        if channelCount == 1, list.count == 1, let data = list[0].mData {
            ring.write(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames))
            return
        }

        // 其餘：所有聲道平均成單聲道
        for index in 0..<frames { output[index] = 0 }
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[index * channels + channel] }
                output[index] += sum
            }
        }
        let scale = 1 / Float(channelCount)
        for index in 0..<frames { output[index] *= scale }
        ring.write(UnsafeBufferPointer(start: output, count: frames))
    }

    /// 音訊中斷後重新開始（換裝置、重新啟動擷取）：下一次不檢查連續性。
    public func resetContinuity() {
        expectedSampleTime.store(Self.none, ordering: .relaxed)
    }
}
