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

/// 讀過一次的 API Key 留在記憶體裡（Key 仍然只存在鑰匙圈，不寫進任何檔案，DESIGN.md 第 6 節）。
///
/// 按下開始時不必每次都讀鑰匙圈：讀的時間算在「按下開始到開始收音」裡，ad-hoc 簽章的版本每次重新編譯之後
/// 第一次讀還會跳出授權視窗。設定頁存入或刪除 Key 時 `invalidate()`，下次重新讀。
public struct CredentialCache: Sendable {
    /// 開始讀鑰匙圈之前拿的號碼牌：讀完連同結果交給 `remember`，讀的途中作廢過就不記。
    public struct Ticket: Sendable, Equatable {
        fileprivate let generation: Int
    }

    private var stored: String?
    private var generation = 0

    public init() {}

    /// 記住的 Key；還沒讀過或已經作廢時是 nil。
    public var key: String? { stored }

    public var ticket: Ticket { Ticket(generation: generation) }

    /// 記住讀到的 Key。只記「讀到了」：沒有 Key、沒有允許與其他錯誤都不記，下次重新讀。
    /// 號碼牌是在 `invalidate()` 之前拿的（讀的途中 Key 被存入或刪除）就不記：讀到的可能是舊的 Key。
    public mutating func remember(_ lookup: CredentialLookup, ticket: Ticket) {
        guard ticket.generation == generation, case .found(let key) = lookup else { return }
        stored = key
    }

    /// 設定頁存入或刪除了 Key：忘掉記住的值，進行中的讀取讀到的也不記。
    public mutating func invalidate() {
        stored = nil
        generation += 1
    }
}

extension CredentialCache: CustomStringConvertible, CustomDebugStringConvertible {
    /// 不含 Key 本身：印出來或寫進 log 也不會外洩（不變條件 5）。
    public var description: String { stored == nil ? "CredentialCache(空的)" : "CredentialCache(<不顯示>)" }

    public var debugDescription: String { description }
}
