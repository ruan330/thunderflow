import CoreAudio
import Foundation

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public final class CaptureMixer: @unchecked Sendable {
    public init(ring: RingBuffer, maximumFrames: Int = 16_384) {}
    public var callbackCount: Int { 0 }
    public var discontinuityCount: Int { 0 }
    public var oversizedCallbackCount: Int { 0 }
    public func process(_ buffers: UnsafePointer<AudioBufferList>, sampleTime: Double?) {}
    public func resetContinuity() {}
}
