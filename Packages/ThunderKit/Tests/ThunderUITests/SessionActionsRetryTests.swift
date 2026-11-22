import Testing
import ThunderUI

@Suite("過去錄音的操作：結束處理失敗的場次可以重試，重試中不能再按、不能刪除")
struct SessionActionsRetryTests {
    @Test("結束處理失敗、現在沒有在處理：顯示「重試」，可以按")
    func failedAndIdle() {
        let actions = SessionActions(progress: nil, failed: true)
        #expect(actions.showsRetry)
        #expect(actions.canRetry)
        #expect(actions.canDelete, "失敗的場次可以刪除")
    }

    @Test("重試中（處理中）：「重試」還在但不能按（不會同時跑兩次），也不能刪除、不能重新產生摘要")
    func retrying() {
        let actions = SessionActions(progress: "合併錄音中", failed: true)
        #expect(actions.showsRetry)
        #expect(!actions.canRetry)
        #expect(!actions.canDelete)
        #expect(!actions.canRegenerateSummary)
    }

    @Test("沒有失敗的場次：不顯示「重試」（處理中或沒在處理都一樣）")
    func notFailed() {
        for progress in [nil, "處理中"] as [String?] {
            let actions = SessionActions(progress: progress)
            #expect(!actions.showsRetry, "\(progress ?? "沒在處理")")
            #expect(!actions.canRetry, "\(progress ?? "沒在處理")")
        }
    }
}
