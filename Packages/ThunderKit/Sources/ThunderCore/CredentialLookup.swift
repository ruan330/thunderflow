import Foundation
import Security

/// 讀取 API Key 的結果（DESIGN.md 第 6 節）。畫面依此說明：沒有 Key 時請使用者去設定；
/// 鑰匙圈沒有允許時 Key 其實還在，不能說成「還沒有設定」。
public enum CredentialLookup: Sendable, Equatable {
    /// 讀到了。
    case found(String)
    /// 鑰匙圈裡沒有（或存的是空字串）。
    case missing
    /// 使用者在鑰匙圈的授權視窗按了拒絕或取消，或現在不能跳出授權視窗。Key 還在，下次讀取時鑰匙圈會再問一次。
    case denied
    /// 其他錯誤。
    case failed(KeychainError)

    /// 執行 `read`（例如 `KeychainStore.read(account:)`）並分類：回傳 nil 或空字串是沒有 Key；
    /// 丟出 `KeychainError` 時依狀態碼分成「沒有允許」與其他錯誤。
    public init(reading read: () throws -> String?) {
        do {
            guard let value = try read(), !value.isEmpty else {
                self = .missing
                return
            }
            self = .found(value)
        } catch let error as KeychainError {
            switch error.outcome {
            case .notFound: self = .missing
            case .denied: self = .denied
            case .success, .failed: self = .failed(error)
            }
        } catch {
            // `KeychainStore` 只會丟出 `KeychainError`；萬一是別的錯誤，也照實當成讀不到
            self = .failed(KeychainError(status: errSecInternalError))
        }
    }
}

extension CredentialLookup: CustomStringConvertible, CustomDebugStringConvertible {
    /// 不含 Key 本身：印出來或寫進 log 也不會外洩（不變條件 5）。
    public var description: String {
        switch self {
        case .found: "found(<不顯示>)"
        case .missing: "missing"
        case .denied: "denied"
        case .failed(let error): "failed(\(error))"
        }
    }

    public var debugDescription: String { description }
}
