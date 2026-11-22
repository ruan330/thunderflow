/// 過去錄音的一場現在能做哪些操作：清單的右鍵選單（DESIGN.md 4.5 節）、詳細頁的「⋯」選單與摘要分頁的按鈕（4.6 節）。
public struct SessionActions: Sendable, Equatable {
    /// 能不能刪除（移到垃圾桶）。
    public let canDelete: Bool
    /// 能不能重新產生摘要。
    public let canRegenerateSummary: Bool

    /// - Parameter progress: 這一場正在處理的進度（結束處理或重新產生摘要）；nil 是沒有在處理。
    public init(progress: String?) {
        // 暫時照目前 App 的做法（一律可以），測試會指出問題；實作時改掉
        canDelete = true
        canRegenerateSummary = true
    }
}
