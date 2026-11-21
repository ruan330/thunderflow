// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
import Foundation
import Security

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知的錯誤"
        return "鑰匙圈錯誤 \(status)：\(message)"
    }
}

/// 把憑證存在 macOS 的鑰匙圈（`kSecClassGenericPassword`）。API Key 只放這裡，
/// 不寫進任何檔案、設定或 log（DESIGN.md 第 6 節）。
public struct KeychainStore: Sendable, Equatable {
    /// 鑰匙圈項目的 service 名稱。App 用自己的 Bundle ID。
    public var service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) throws -> String? { nil }
    public func save(_ value: String, account: String) throws {}
    public func delete(account: String) throws {}
}
