import Foundation

public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let limit: Duration
    public var description: String { "超過時限 \(limit) 仍未完成" }
}

/// 執行 `operation`，超過時限就丟出 `DeadlineExceeded`。
///
/// 目的是讓「卡住」變成一個明確的測試失敗，而不是讓整個測試流程停在那裡。
/// 逾時後原本的工作會被取消，但不會等它結束。
@discardableResult
public func withDeadline<Value: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let resumed = LockedValue(false)
    @Sendable func claim() -> Bool {
        resumed.withValue { already in
            if already { return false }
            already = true
            return true
        }
    }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
        let work = Task {
            do {
                let value = try await operation()
                if claim() { continuation.resume(returning: value) }
            } catch {
                if claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            if claim() {
                work.cancel()
                continuation.resume(throwing: DeadlineExceeded(limit: limit))
            }
        }
    }
}

/// 同步版本：在另一條執行緒執行 `operation`，回傳它是否在時限內完成。
/// 逾時的話那條執行緒會被放著不管（測試已經失敗了）。
public func completesWithin(_ limit: Duration, _ operation: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        operation()
        done.signal()
    }
    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    return done.wait(timeout: .now() + seconds) == .success
}

/// 等到 `condition` 成立。超過時限回傳 false。
public func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        usleep(200)
    }
    return true
}
