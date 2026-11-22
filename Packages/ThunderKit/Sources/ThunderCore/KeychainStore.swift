import Foundation
import Security

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    /// 這個錯誤屬於哪一類（使用者沒有允許、其他錯誤……），畫面依此說明。
    public var outcome: KeychainOutcome { KeychainOutcome(status: status) }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知的錯誤"
        return "鑰匙圈錯誤 \(status)：\(message)"
    }
}

/// 鑰匙圈操作的結果，依畫面該怎麼說分類。只看狀態碼，不碰鑰匙圈。
public enum KeychainOutcome: Sendable, Equatable {
    /// 成功。
    case success
    /// 沒有這個項目。
    case notFound
    /// 使用者在鑰匙圈的授權視窗按了拒絕或取消，或現在不能跳出授權視窗（例如鑰匙圈鎖著又不能詢問）。
    /// 項目還在，只是這一次沒有拿到，不能說成「沒有 Key」。
    case denied
    /// 其他錯誤，帶原本的狀態碼。
    case failed(OSStatus)

    public init(status: OSStatus) {
        self = .failed(status)
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

    /// 讀出存著的值；沒有這個項目時回傳 nil。
    public func read(account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    /// 存入（已經有就覆寫）。
    public func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = base(account)
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// 刪除。原本就沒有也不算錯。
    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
