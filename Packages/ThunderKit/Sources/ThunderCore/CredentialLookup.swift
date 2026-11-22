import Foundation

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
        self = .missing
    }
}
