import Foundation

/// 錄音路徑的搬運工：用一條專用執行緒，定期把 RingBuffer 裡的樣本交給 handler。
///
/// 刻意不使用 Swift concurrency：錄音路徑不能因為共用執行緒池忙碌而被延遲。
/// handler 一律在同一條專用執行緒上被呼叫，裡面只能做錄音路徑的工作
/// （寫檔、轉格式、把音訊放進引擎的等待區），不可以等待網路或引擎。
public final class Pump: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafeBufferPointer<Float>) -> Void

    /// - Parameters:
    ///   - interval: 緩衝區空了之後，隔多久再看一次。
    ///   - maxSamplesPerCall: 每次交給 handler 的樣本數上限。
    public init(
        ring: RingBuffer,
        interval: Duration = .milliseconds(20),
        maxSamplesPerCall: Int = 9_600,
        handler: @escaping Handler
    ) {}

    public var isRunning: Bool { false }

    /// 啟動專用執行緒。
    public func start() {}

    /// 停止。返回前會先把緩衝區裡剩下的樣本交給 handler，而且不必等完整個 interval。
    /// 返回之後 handler 不會再被呼叫。重複呼叫不算錯。
    public func stop() {}
}
