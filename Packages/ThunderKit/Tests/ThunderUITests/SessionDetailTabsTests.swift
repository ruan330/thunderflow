import Testing
import ThunderUI

@Suite("單場詳細頁的分頁：只在第一次讀到內容時決定先看哪一頁")
struct SessionDetailTabsTests {
    @Test("還沒讀到內容時：顯示逐字稿")
    func beforeLoading() {
        #expect(SessionDetailTabs().selected == .transcript)
    }

    @Test("第一次讀到內容時有摘要：先看摘要")
    func firstLoadWithSummary() {
        var tabs = SessionDetailTabs()
        tabs.contentLoaded(hasSummary: true)
        #expect(tabs.selected == .summary)
    }

    @Test("第一次讀到內容時還沒有摘要：看逐字稿")
    func firstLoadWithoutSummary() {
        var tabs = SessionDetailTabs()
        tabs.contentLoaded(hasSummary: false)
        #expect(tabs.selected == .transcript)
    }

    @Test("看著逐字稿時摘要才做好（重新讀到內容）：仍是逐字稿，不會被切到摘要")
    func summaryArrivesLater() {
        var tabs = SessionDetailTabs()
        tabs.contentLoaded(hasSummary: false)
        // 處理的進度更新、摘要做好、資料夾自動改名：每一次都重新讀檔
        tabs.contentLoaded(hasSummary: false)
        tabs.contentLoaded(hasSummary: true)
        tabs.contentLoaded(hasSummary: true)
        #expect(tabs.selected == .transcript)
    }

    @Test("使用者從摘要切到逐字稿之後再讀到內容：不會被改回摘要")
    func keepsUserChoice() {
        var tabs = SessionDetailTabs()
        tabs.contentLoaded(hasSummary: true)
        tabs.selected = .transcript
        tabs.contentLoaded(hasSummary: true)
        #expect(tabs.selected == .transcript)
    }

    @Test("使用者切到摘要之後再讀到內容（例如重新產生摘要中、暫時沒有摘要）：仍是摘要")
    func keepsSummaryWhenItDisappears() {
        var tabs = SessionDetailTabs()
        tabs.contentLoaded(hasSummary: false)
        tabs.selected = .summary
        tabs.contentLoaded(hasSummary: false)
        #expect(tabs.selected == .summary)
    }

    @Test("分頁的名稱：摘要、逐字稿，依這個順序排")
    func names() {
        #expect(SessionDetailTabs.Tab.allCases.map(\.rawValue) == ["摘要", "逐字稿"])
    }
}
