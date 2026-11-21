import Foundation

/// 以鎖保護的值，可以安全地跨執行緒讀寫。只給測試用。
public final class LockedValue<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    public init(_ value: Value) { storage = value }

    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

/// 可以重現的亂數產生器（SplitMix64）：同一個 seed 每次產生同樣的序列，測試結果才會固定。
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
