import Foundation

/// 測試用的暫存資料夾。
///
/// 用法（`defer` 同時確保資料夾在整個測試期間都存在）：
///
///     let tmp = try TemporaryDirectory()
///     defer { tmp.remove() }
public struct TemporaryDirectory: Sendable {
    public let url: URL

    public init(prefix: String = "thunder-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
