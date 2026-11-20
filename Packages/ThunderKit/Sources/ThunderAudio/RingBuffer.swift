import Foundation

/// 單一寫入者、單一讀取者的無鎖環形緩衝區，存放 Float32 樣本。
///
/// 寫入端是音訊裝置的即時執行緒：`write` 不配置記憶體、不上鎖、不等待。
/// 讀取端是 Pump 的專用執行緒。除此之外不可以有第二個寫入者或第二個讀取者。
public final class RingBuffer: @unchecked Sendable {
    private let requestedCapacity: Int

    /// - Parameter minimumCapacity: 至少要能放多少個樣本。實際容量可能更大。
    public init(minimumCapacity: Int) {
        requestedCapacity = minimumCapacity
    }

    /// 最多能同時存放的樣本數。
    public var capacity: Int { requestedCapacity }

    /// 目前可以讀出的樣本數。
    public var availableToRead: Int { 0 }

    /// 目前還能寫入的樣本數。
    public var availableToWrite: Int { 0 }

    /// 累計因為空間不足而沒寫進去的樣本數。不是 0 就代表掉音了。
    public var droppedSampleCount: Int { 0 }

    /// 寫入樣本（只能由寫入端呼叫）。空間不夠時能寫多少寫多少，其餘計入 `droppedSampleCount`。
    /// - Returns: 實際寫入的樣本數。
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        0 // 尚未實作
    }

    /// 讀出樣本（只能由讀取端呼叫）。
    /// - Returns: 實際讀到的樣本數，最多是 `buffer.count`。
    @discardableResult
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        0 // 尚未實作
    }
}
