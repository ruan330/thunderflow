import Foundation
import Observation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
@MainActor
@Observable
public final class LiveCaptionModel {
    public private(set) var board = CaptionBoard()
    public private(set) var engineStatus: EngineStatus?
    public private(set) var billedSeconds: Double = 0
    public private(set) var gapSeconds: Double = 0
    public private(set) var updateCount = 0
    public static let minimumInterval: Duration = .milliseconds(33)

    public init() {}
    nonisolated public func receive(_ event: CaptionEvent) {}
    public func engineEnded() {}
    public func reset() {}
    public func flush() {}
}
