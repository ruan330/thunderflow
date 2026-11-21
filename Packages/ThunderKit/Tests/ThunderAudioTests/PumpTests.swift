import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

@Suite("Pump：專用執行緒把樣本從 RingBuffer 交給錄音路徑")
struct PumpTests {
    /// 模擬音訊裝置的 callback：每次寫 480 個樣本，緩衝區有空間就寫。回傳實際寫入的樣本數。
    private func writeLikeAudioCallback(into ring: RingBuffer, total: Int) -> Int {
        var sent = 0
        var lastProgress = ContinuousClock.now
        while sent < total {
            if ring.availableToWrite >= 480 {
                sent += ring.write(Signal.sequence(from: sent, count: 480))
                lastProgress = ContinuousClock.now
            } else {
                if ContinuousClock.now - lastProgress > .seconds(2) { break }
                usleep(100)
            }
        }
        return sent
    }

    /// 這個測試也要在 Thread Sanitizer 下執行（make test-tsan）。
    @Test("另一條執行緒持續寫入時，交出的樣本一個不少、順序不亂")
    func deliversEverythingInOrder() {
        let ring = RingBuffer(minimumCapacity: 48_000)
        let received = LockedValue<[Float]>([])
        let pump = Pump(ring: ring, interval: .milliseconds(2)) { samples in
            received.withValue { $0.append(contentsOf: samples) }
        }

        pump.start()
        #expect(pump.isRunning)
        let sent = writeLikeAudioCallback(into: ring, total: 96_000)
        pump.stop()

        #expect(!pump.isRunning)
        #expect(sent == 96_000)
        #expect(received.value.count == 96_000)
        #expect(Signal.firstMismatch(in: received.value, sequenceFrom: 0) == nil)
        #expect(ring.droppedSampleCount == 0)
        #expect(ring.availableToRead == 0)
    }

    @Test("stop() 先把剩下的樣本交完才返回，而且不必等完整個 interval")
    func stopDrainsPromptly() {
        let ring = RingBuffer(minimumCapacity: 16_384)
        let received = LockedValue<[Float]>([])
        // interval 設成一分鐘：只有 stop() 的排空能在時限內把資料送出來
        let pump = Pump(ring: ring, interval: .seconds(60)) { samples in
            received.withValue { $0.append(contentsOf: samples) }
        }

        pump.start()
        usleep(20_000)
        ring.write(Signal.sequence(from: 0, count: 10_000))
        let stoppedInTime = completesWithin(.seconds(2)) { pump.stop() }

        #expect(stoppedInTime)
        // 啟動時可能已經先看過一次緩衝區，所以這裡只要求「最後全部都交出來了」
        #expect(received.value.count == 10_000)
        #expect(Signal.firstMismatch(in: received.value, sequenceFrom: 0) == nil)
    }

    @Test("每次交給 handler 的樣本數不超過上限")
    func respectsMaxSamplesPerCall() {
        let ring = RingBuffer(minimumCapacity: 16_384)
        let sizes = LockedValue<[Int]>([])
        let pump = Pump(ring: ring, interval: .milliseconds(2), maxSamplesPerCall: 1_000) { samples in
            sizes.withValue { $0.append(samples.count) }
        }

        ring.write(Signal.sequence(from: 0, count: 10_000))
        pump.start()
        pump.stop()

        #expect(sizes.value.reduce(0, +) == 10_000)
        #expect(sizes.value.allSatisfy { $0 > 0 && $0 <= 1_000 })
    }

    @Test("handler 一律在同一條專用執行緒上執行，不是主執行緒")
    func runsOnOneDedicatedThread() {
        let ring = RingBuffer(minimumCapacity: 48_000)
        let threads = LockedValue<Set<UInt>>([])
        let sawMainThread = LockedValue(false)
        let pump = Pump(ring: ring, interval: .milliseconds(1)) { _ in
            let identifier = UInt(bitPattern: pthread_self())
            threads.withValue { _ = $0.insert(identifier) }
            if Thread.isMainThread { sawMainThread.withValue { $0 = true } }
        }

        pump.start()
        _ = writeLikeAudioCallback(into: ring, total: 48_000)
        pump.stop()

        #expect(threads.value.count == 1)
        #expect(!sawMainThread.value)
    }

    @Test("stop() 之後不再呼叫 handler；重複 stop() 不算錯")
    func quietAfterStop() {
        let ring = RingBuffer(minimumCapacity: 4_096)
        let calls = LockedValue(0)
        let pump = Pump(ring: ring, interval: .milliseconds(1)) { _ in calls.withValue { $0 += 1 } }

        pump.start()
        ring.write(Signal.sequence(from: 0, count: 1_000))
        pump.stop()
        let callsAtStop = calls.value
        pump.stop()

        ring.write(Signal.sequence(from: 0, count: 1_000))
        usleep(30_000)

        #expect(callsAtStop >= 1)
        #expect(calls.value == callsAtStop)
        #expect(ring.availableToRead == 1_000)
    }
}
