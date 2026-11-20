import Foundation

/// 錄音路徑的搬運工：用一條專用執行緒，定期把 RingBuffer 裡的樣本交給 handler。
///
/// 刻意不使用 Swift concurrency：錄音路徑不能因為共用執行緒池忙碌而被延遲。
/// handler 一律在同一條專用執行緒上被呼叫，裡面只能做錄音路徑的工作
/// （寫檔、轉格式、把音訊放進引擎的等待區），不可以等待網路或引擎。
///
/// 執行緒每一輪先把緩衝區讀空（每次最多 `maxSamplesPerCall` 個樣本），再休息 `interval`；
/// `stop()` 會立刻叫醒它。`start()`、`stop()` 可以從任何執行緒呼叫，
/// 但不可以在 handler 裡呼叫 `stop()`（它會等這條執行緒結束，等於等自己）。
public final class Pump: @unchecked Sendable {
    // @unchecked Sendable：`phase` 與 `threadExited` 只在 `condition` 的鎖裡讀寫；
    // `scratch` 只由專用執行緒使用，它的建立與釋放分別發生在執行緒啟動之前與結束之後；
    // 其餘都是建立後不再改變的常數（`ring` 本身是 thread-safe 的單一讀寫者佇列）。
    public typealias Handler = @Sendable (UnsafeBufferPointer<Float>) -> Void

    private enum Phase {
        case idle
        case running
        case stopping
    }

    private let ring: RingBuffer
    private let intervalSeconds: TimeInterval
    private let handler: Handler
    /// 專用執行緒讀取用的緩衝區，大小就是每次交給 handler 的上限。事先配置好，執行中不再配置記憶體。
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let condition = NSCondition()
    private var phase = Phase.idle
    private var threadExited = true

    /// - Parameters:
    ///   - interval: 緩衝區空了之後，隔多久再看一次。
    ///   - maxSamplesPerCall: 每次交給 handler 的樣本數上限。
    public init(
        ring: RingBuffer,
        interval: Duration = .milliseconds(20),
        maxSamplesPerCall: Int = 9_600,
        handler: @escaping Handler
    ) {
        self.ring = ring
        let components = interval.components
        intervalSeconds = max(0, Double(components.seconds) + Double(components.attoseconds) * 1e-18)
        self.handler = handler
        scratch = .allocate(capacity: max(1, maxSamplesPerCall))
        scratch.initialize(repeating: 0)
    }

    deinit {
        // 執行緒在跑的時候會持有 self，所以走到這裡時執行緒一定已經結束
        scratch.deallocate()
    }

    /// 從 `start()` 返回起，到 `stop()` 返回為止是 true。
    public var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase != .idle
    }

    /// 啟動專用執行緒。已經在執行就不做任何事。
    public func start() {
        condition.lock()
        defer { condition.unlock() }
        // 另一條執行緒正在 stop()：等它停好再重新啟動
        while phase == .stopping { condition.wait() }
        guard phase == .idle else { return }
        phase = .running
        threadExited = false
        let thread = Thread { [self] in run() }
        thread.name = "ThunderFlow.Pump"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 停止。返回前會先把緩衝區裡剩下的樣本交給 handler，而且不必等完整個 interval。
    /// 返回之後 handler 不會再被呼叫。重複呼叫不算錯。
    ///
    /// 「剩下的樣本」是指呼叫 `stop()` 時已經在緩衝區裡的樣本；之後才寫入的樣本會留在緩衝區裡。
    public func stop() {
        condition.lock()
        defer { condition.unlock() }
        // 另一條執行緒正在 stop()：等它完成，這樣兩個呼叫者返回時都保證 handler 不會再被呼叫
        while phase == .stopping { condition.wait() }
        guard phase == .running else { return }
        phase = .stopping
        condition.broadcast()
        while !threadExited { condition.wait() }
        phase = .idle
        condition.broadcast()
    }

    // MARK: 專用執行緒

    private func run() {
        while true {
            // 每一輪只交出這一輪開始時已經在緩衝區裡的樣本，所以寫入端再快，也能在輪與輪之間發現 stop()
            autoreleasepool { deliverAvailable(upTo: ring.availableToRead) }
            condition.lock()
            if phase == .running && ring.availableToRead == 0 {
                _ = condition.wait(until: Date(timeIntervalSinceNow: intervalSeconds))
            }
            let stopping = phase == .stopping
            condition.unlock()
            if stopping { break }
        }
        // 最後一次排空：交出 stop() 時已經在緩衝區裡的樣本
        autoreleasepool { deliverAvailable(upTo: ring.availableToRead) }
        condition.lock()
        threadExited = true
        condition.broadcast()
        condition.unlock()
    }

    /// 把緩衝區裡的樣本分批交給 handler，直到讀空或交滿 `limit` 個。
    private func deliverAvailable(upTo limit: Int) {
        var remaining = limit
        while remaining > 0 {
            let destination = UnsafeMutableBufferPointer(rebasing: scratch[0..<min(scratch.count, remaining)])
            let count = ring.read(into: destination)
            guard count > 0 else { return }
            handler(UnsafeBufferPointer(rebasing: scratch[0..<count]))
            remaining -= count
        }
    }
}
