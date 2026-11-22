import Foundation
import Testing
import ThunderCore
import ThunderUI

@Suite("過去錄音的狀態標籤：結束處理失敗、還留在工作目錄的場次")
struct SessionBadgeFailureTests {
    private let stuck = SessionMeta(
        startedAt: Date(timeIntervalSince1970: 1_800_000_000), state: .finalizing, completedSteps: ["blocks", "transcript"])

    @Test("結束處理失敗：顯示「處理失敗」，用警告符號與危險的色調（不只靠顏色）")
    func failed() {
        #expect(Indicator.sessionBadge(stuck, failed: true) == Indicator(symbol: .warning, tone: .danger, text: "處理失敗"))
    }

    @Test("處理失敗之後又在重試（有進度）：顯示進度，不顯示處理失敗")
    func retrying() {
        #expect(
            Indicator.sessionBadge(stuck, progress: "合併錄音中", failed: true)
                == Indicator(symbol: .spinner, tone: .neutral, text: "合併錄音中"))
    }

    @Test("沒有失敗、還沒做完：和原本一樣顯示「處理中」")
    func notFailed() {
        #expect(Indicator.sessionBadge(stuck) == Indicator(symbol: .spinner, tone: .neutral, text: "處理中"))
    }
}
