import Testing
import ThunderUI

@Suite("過去錄音的操作：處理中的場次不能刪除、不能重新產生摘要")
struct SessionActionsTests {
    @Test("沒有在處理的場次：可以刪除，也可以重新產生摘要")
    func idle() {
        let actions = SessionActions(progress: nil)
        #expect(actions.canDelete)
        #expect(actions.canRegenerateSummary)
    }

    @Test("處理中的場次（不論做到哪一步）：不能刪除，免得資料夾在寫到一半時被搬進垃圾桶")
    func noDeleteWhileProcessing() {
        for progress in ["處理中", "合併錄音中", "整理資料夾中", "產生摘要中", "完成"] {
            #expect(!SessionActions(progress: progress).canDelete, "\(progress)")
        }
    }

    @Test("處理中的場次：不能重新產生摘要（同一場同時只能有一個處理）")
    func noRegenerationWhileProcessing() {
        for progress in ["處理中", "合併錄音中", "整理資料夾中", "產生摘要中", "完成"] {
            #expect(!SessionActions(progress: progress).canRegenerateSummary, "\(progress)")
        }
    }
}
