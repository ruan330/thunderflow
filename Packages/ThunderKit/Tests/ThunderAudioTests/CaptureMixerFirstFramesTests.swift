import CoreAudio
import Darwin
import Foundation
import Testing
import ThunderAudio

/// 一批單聲道的樣本（`AudioBufferList`）。`frames` 是 0 時是空的一批（裝置有呼叫 callback，但沒有給樣本）。
private func process(_ mixer: CaptureMixer, frames: Int) {
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
    defer { data.deallocate() }
    data.initialize(repeating: 0.1, count: max(frames, 1))
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: data)
    mixer.process(UnsafePointer(list.unsafePointer), sampleTime: nil)
}

/// 「按下開始到第一個樣本進來」（`session.startToCapture`，DESIGN.md 9.8 節）要在實機上量，
/// 所以擷取外殼記下第一次收到樣本的時間，App 拿它和按下開始的時間相減。
@Suite("擷取外殼：第一次收到樣本的時間")
struct CaptureMixerFirstFramesTests {
    @Test("還沒收到樣本時沒有時間；空的 callback 不算；收到第一批之後記下時間，之後的 callback 不改變它")
    func recordsFirstFrames() throws {
        let mixer = CaptureMixer(ring: RingBuffer(minimumCapacity: 4_096))
        #expect(mixer.firstFramesUptimeNanoseconds == nil)

        process(mixer, frames: 0)
        #expect(mixer.firstFramesUptimeNanoseconds == nil)

        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        process(mixer, frames: 256)
        let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let first = try #require(mixer.firstFramesUptimeNanoseconds)
        #expect(first >= before)
        #expect(first <= after)

        process(mixer, frames: 256)
        #expect(mixer.firstFramesUptimeNanoseconds == first)
    }
}
