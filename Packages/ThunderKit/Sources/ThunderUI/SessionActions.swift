/// 過去錄音的一場現在能做哪些操作：清單的右鍵選單（DESIGN.md 4.5 節）、詳細頁的「⋯」選單與摘要分頁的按鈕（4.6 節）。
public struct SessionActions: Sendable, Equatable {
    /// 能不能刪除（移到垃圾桶）。處理中不行：結束處理還在寫這個資料夾，這時搬走會讓它寫到一半。
    public let canDelete: Bool
    /// 能不能重新產生摘要。處理中不行：同一場同時只能有一個處理（`SessionLock`），按下去只會失敗。
    public let canRegenerateSummary: Bool
    /// 要不要顯示「重試」。
    public let showsRetry: Bool
    /// 「重試」能不能按。
    public let canRetry: Bool

    /// - Parameters:
    ///   - progress: 這一場正在處理的進度（結束處理或重新產生摘要）；nil 是沒有在處理。
    ///   - failed: 這一場的結束處理失敗了（清單上標「處理失敗」）。
    public init(progress: String?, failed: Bool = false) {
        let idle = progress == nil
        canDelete = idle
        canRegenerateSummary = idle
        // 暫時照目前的做法（沒有重試），測試會指出問題；實作時改掉
        showsRetry = false
        canRetry = false
    }
}
