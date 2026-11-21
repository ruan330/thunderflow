import Foundation
import Synchronization

/// 單一寫入者、單一讀取者的無鎖環形緩衝區，存放 Float32 樣本。
///
/// 寫入端是音訊裝置的即時執行緒：`write` 不配置記憶體、不上鎖、不等待。
/// 讀取端是 Pump 的專用執行緒。除此之外不可以有第二個寫入者或第二個讀取者。
///
/// 做法：記憶體在建立時一次配置好；讀、寫各有一個只增不減的計數器（`Synchronization.Atomic`），
/// 位置是計數器對容量取餘數（容量是 2 的次方，所以用位元遮罩）。寫入端先複製樣本、
/// 再以 release 更新寫入計數；讀取端以 acquire 讀到寫入計數後才複製樣本，反過來也一樣。
/// 因此兩端不需要任何鎖，Thread Sanitizer 也看得懂這個同步關係。
/// 可以用的空間剛好是 `capacity`（不需要保留一格來分辨空與滿）。
public final class RingBuffer: @unchecked Sendable {
    // @unchecked Sendable：`storage` 的內容只由上述的計數器協定保護（單一寫入者、單一讀取者），
    // 其餘的狀態都是建立後不再改變的常數或 Atomic。
    private let requestedCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    /// 累計寫入的樣本數。只有寫入端會修改。
    private let writeCount = Atomic<Int>(0)
    /// 累計讀出的樣本數。只有讀取端會修改。
    private let readCount = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    /// - Parameter minimumCapacity: 至少要能放多少個樣本。實際容量可能更大（2 的次方）。
    public init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        requestedCapacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// 最多能同時存放的樣本數。
    public var capacity: Int { requestedCapacity }

    /// 目前可以讀出的樣本數。可以從任何執行緒呼叫（別的執行緒看到的是那一瞬間的近似值）。
    public var availableToRead: Int {
        // 先讀「讀取計數」再讀「寫入計數」：兩者都只增不減，所以差值不會是負的
        let read = readCount.load(ordering: .acquiring)
        let written = writeCount.load(ordering: .acquiring)
        return min(max(written &- read, 0), requestedCapacity)
    }

    /// 目前還能寫入的樣本數。可以從任何執行緒呼叫；對寫入端來說是準確的下限（讀取端只會讓它變大）。
    public var availableToWrite: Int { requestedCapacity - availableToRead }

    /// 累計因為空間不足而沒寫進去的樣本數。不是 0 就代表掉音了。
    public var droppedSampleCount: Int { dropped.load(ordering: .relaxed) }

    /// 寫入樣本（只能由寫入端呼叫）。空間不夠時能寫多少寫多少，其餘計入 `droppedSampleCount`。
    /// 不配置記憶體、不上鎖、不等待：只有兩次 memcpy 與幾個 atomic 操作。
    /// - Returns: 實際寫入的樣本數。
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let source = samples.baseAddress, samples.count > 0 else { return 0 }
        let written = writeCount.load(ordering: .relaxed)
        let read = readCount.load(ordering: .acquiring)
        let count = min(requestedCapacity - (written &- read), samples.count)
        if count > 0 {
            let start = written & mask
            let first = min(count, requestedCapacity - start)
            copy(from: source, to: storage + start, count: first)
            if count > first { copy(from: source + first, to: storage, count: count - first) }
            writeCount.store(written &+ count, ordering: .releasing)
        }
        if count < samples.count {
            dropped.add(samples.count - count, ordering: .relaxed)
        }
        return count
    }

    /// 讀出樣本（只能由讀取端呼叫）。
    /// - Returns: 實際讀到的樣本數，最多是 `buffer.count`。
    @discardableResult
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let destination = buffer.baseAddress, buffer.count > 0 else { return 0 }
        let read = readCount.load(ordering: .relaxed)
        let written = writeCount.load(ordering: .acquiring)
        let count = min(written &- read, buffer.count)
        guard count > 0 else { return 0 }
        let start = read & mask
        let first = min(count, requestedCapacity - start)
        copy(from: storage + start, to: destination, count: first)
        if count > first { copy(from: storage, to: destination + first, count: count - first) }
        readCount.store(read &+ count, ordering: .releasing)
        return count
    }

    @inline(__always)
    private func copy(from source: UnsafePointer<Float>, to destination: UnsafeMutablePointer<Float>, count: Int) {
        UnsafeMutableRawPointer(destination).copyMemory(from: source, byteCount: count * MemoryLayout<Float>.stride)
    }
}
