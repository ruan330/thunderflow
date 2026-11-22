/// 單場詳細頁的兩個分頁（DESIGN.md 4.6 節）：摘要與逐字稿。
///
/// 一開始看哪一頁，只在第一次讀到這一場的內容時決定：有摘要就先看摘要，沒有就看逐字稿。
/// 之後再讀到新的內容（處理的進度、摘要做好了、資料夾因為自動命名改了名）都不換分頁：
/// 使用者正在讀逐字稿或聽錄音時，摘要做好了也不會把畫面切走；使用者自己選的分頁也不會被改回去。
public struct SessionDetailTabs: Sendable, Equatable {
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case summary = "摘要"
        case transcript = "逐字稿"
    }

    /// 現在顯示的分頁。使用者切換分頁時直接改它。
    public var selected: Tab = .transcript
    /// 已經讀到過內容了沒有：讀到過之後，分頁只由使用者切換。
    private var decided = false

    public init() {}

    /// 讀到這一場的內容了（每次重新讀檔都呼叫）。只有第一次會決定分頁。
    ///
    /// - Parameter hasSummary: 讀到的內容裡有沒有摘要。
    public mutating func contentLoaded(hasSummary: Bool) {
        guard !decided else { return }
        decided = true
        if hasSummary { selected = .summary }
    }
}
