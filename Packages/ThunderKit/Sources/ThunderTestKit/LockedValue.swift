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
