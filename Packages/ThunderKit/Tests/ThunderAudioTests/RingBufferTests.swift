import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

@Suite("RingBuffer：即時執行緒與 Pump 之間的無鎖緩衝區")
struct RingBufferTests {
    @Test("容量至少是要求的大小", arguments: [1, 100, 1_000, 48_000, 480_001])
    func capacityIsAtLeastRequested(requested: Int) {
        #expect(RingBuffer(minimumCapacity: requested).capacity >= requested)
    }

    @Test("新建立的緩衝區是空的：讀不到東西，整個容量都可以寫")
    func startsEmpty() {
        let ring = RingBuffer(minimumCapacity: 1_024)

        #expect(ring.availableToRead == 0)
        #expect(ring.availableToWrite == ring.capacity)
        #expect(ring.read(maxCount: 256).isEmpty)
        #expect(ring.droppedSampleCount == 0)
    }

    @Test("寫進去的樣本照原順序讀出來，可以分次讀")
    func readsBackInOrder() {
        let ring = RingBuffer(minimumCapacity: 1_024)
        let input = Signal.sequence(from: 0, count: 500)

        #expect(ring.write(input) == 500)
        #expect(ring.availableToRead == 500)
        #expect(ring.availableToWrite == ring.capacity - 500)

        #expect(ring.read(maxCount: 200) == Array(input[0..<200]))
        #expect(ring.read(maxCount: 1_000) == Array(input[200...]))
        #expect(ring.availableToRead == 0)
        #expect(ring.droppedSampleCount == 0)
    }

    @Test("反覆寫入讀出、繞過緩衝區尾端很多次，資料不變")
    func survivesWraparound() throws {
        let ring = RingBuffer(minimumCapacity: 1_000)
        var written = 0
        var verified = 0

        for round in 0..<5_000 {
            let count = 1 + (round * 37) % 613
            try #require(ring.write(Signal.sequence(from: written, count: count)) == count, "第 \(round) 輪寫入失敗")
            written += count

            let output = ring.read(maxCount: 1 + (round * 53) % 701)
            if let mismatch = Signal.firstMismatch(in: output, sequenceFrom: verified) {
                Issue.record("第 \(round) 輪：第 \(verified + mismatch) 個樣本不對")
                return
            }
            verified += output.count
            // 讀得比寫得慢時先把積壓的讀掉，避免緩衝區被塞滿
            while ring.availableToRead > 300 {
                let extra = ring.read(maxCount: 300)
                try #require(Signal.firstMismatch(in: extra, sequenceFrom: verified) == nil, "第 \(round) 輪讀出的資料不對")
                verified += extra.count
            }
        }
        let rest = ring.read(maxCount: ring.capacity)
        #expect(Signal.firstMismatch(in: rest, sequenceFrom: verified) == nil)
        verified += rest.count

        #expect(verified == written)
        #expect(written > ring.capacity * 100)
        #expect(ring.droppedSampleCount == 0)
    }

    @Test("空間不夠時：能寫多少寫多少，其餘計入丟棄數；已經在裡面的資料不受影響")
    func overflowDropsNewSamplesAndCounts() {
        let ring = RingBuffer(minimumCapacity: 1_000)
        let capacity = ring.capacity

        #expect(ring.write(Signal.sequence(from: 0, count: capacity - 10)) == capacity - 10)
        #expect(ring.write(Signal.sequence(from: capacity - 10, count: 50)) == 10)
        #expect(ring.droppedSampleCount == 40)
        #expect(ring.availableToRead == capacity)
        #expect(ring.availableToWrite == 0)

        // 滿了之後再寫：全部丟棄
        #expect(ring.write(Signal.sequence(from: 0, count: 25)) == 0)
        #expect(ring.droppedSampleCount == 65)

        // 前 capacity 個樣本原封不動
        let output = ring.read(maxCount: capacity + 100)
        #expect(output.count == capacity)
        #expect(Signal.firstMismatch(in: output, sequenceFrom: 0) == nil)

        // 讀空之後可以繼續正常使用，丟棄數不會再增加
        #expect(ring.write(Signal.sequence(from: 0, count: 100)) == 100)
        #expect(ring.read(maxCount: 100) == Signal.sequence(from: 0, count: 100))
        #expect(ring.droppedSampleCount == 65)
    }

    @Test("讀的緩衝區比現有資料小：只讀那麼多，剩下的留著")
    func partialRead() {
        let ring = RingBuffer(minimumCapacity: 64)
        ring.write(Signal.sequence(from: 0, count: 10))

        #expect(ring.read(maxCount: 4) == Signal.sequence(from: 0, count: 4))
        #expect(ring.availableToRead == 6)
        #expect(ring.read(maxCount: 0).isEmpty)
        #expect(ring.read(maxCount: 100) == Signal.sequence(from: 4, count: 6))
    }

    /// 這個測試也要在 Thread Sanitizer 下執行（make test-tsan）。
    @Test("一條執行緒寫、另一條讀：五百萬個樣本一個不少、順序不亂")
    func concurrentProducerConsumerLosesNothing() {
        let ring = RingBuffer(minimumCapacity: 4_096)
        let total = 5_000_000
        let producerDone = LockedValue(false)

        let producer = Thread {
            var sent = 0
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            var lastProgress = ContinuousClock.now
            while sent < total {
                let space = ring.availableToWrite
                if space == 0 {
                    // 兩秒都沒有空間：對面沒有在讀（或尚未實作），放棄，讓測試以「數量不符」失敗
                    if ContinuousClock.now - lastProgress > .seconds(2) { break }
                    usleep(50)
                    continue
                }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let count = min(total - sent, space, 1 + Int(seed >> 33) % 512)
                sent += ring.write(Signal.sequence(from: sent, count: count))
                lastProgress = ContinuousClock.now
            }
            producerDone.withValue { $0 = true }
        }
        producer.start()

        var received = 0
        var seed: UInt64 = 0xD1B5_4A32_D192_ED03
        var lastProgress = ContinuousClock.now
        var firstBadSample: Int?
        while received < total {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let output = ring.read(maxCount: 1 + Int(seed >> 33) % 700)
            if output.isEmpty {
                if ContinuousClock.now - lastProgress > .seconds(2) { break }
                if producerDone.value && ring.availableToRead == 0 { break }
                continue
            }
            if let mismatch = Signal.firstMismatch(in: output, sequenceFrom: received) {
                firstBadSample = received + mismatch
                break
            }
            received += output.count
            lastProgress = ContinuousClock.now
        }
        while !producer.isFinished { usleep(1_000) }

        #expect(firstBadSample == nil)
        #expect(received == total)
        #expect(ring.droppedSampleCount == 0)
    }
}
