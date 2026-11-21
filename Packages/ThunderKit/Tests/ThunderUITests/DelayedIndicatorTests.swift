import Testing
import ThunderUI

@Suite("延遲顯示「準備中」：等待滿 0.3 秒才出現")
struct DelayedIndicatorTests {
    @Test("還沒開始等待時不顯示；等待未滿 0.3 秒不顯示，剛好 0.3 秒與之後才顯示")
    func reveal() {
        var indicator = DelayedIndicator()
        #expect(!indicator.isVisible(at: ms(0)))
        #expect(indicator.revealsAt == nil)

        indicator.begin(at: ms(0))
        #expect(indicator.revealsAt == ms(300))
        #expect(!indicator.isVisible(at: ms(0)))
        #expect(!indicator.isVisible(at: ms(299)))
        #expect(indicator.isVisible(at: ms(300)))
        #expect(indicator.isVisible(at: ms(301)))
    }

    @Test("0.3 秒內就等完了：「準備中」一直不出現，也不需要再重畫")
    func endedBeforeReveal() {
        var indicator = DelayedIndicator()
        indicator.begin(at: ms(0))
        #expect(indicator.revealsAt == ms(300))

        indicator.end()
        #expect(!indicator.isVisible(at: ms(300)))
        #expect(!indicator.isVisible(at: ms(5_000)))
        #expect(indicator.revealsAt == nil)
    }

    @Test("「準備中」出現之後等完了：馬上消失；下一次等待從新的時間點重新計算 0.3 秒")
    func endedAfterReveal() {
        var indicator = DelayedIndicator()
        indicator.begin(at: ms(0))
        #expect(indicator.isVisible(at: ms(1_000)))

        indicator.end()
        #expect(!indicator.isVisible(at: ms(1_000)))

        indicator.begin(at: ms(2_000))
        #expect(indicator.revealsAt == ms(2_300))
        #expect(!indicator.isVisible(at: ms(2_299)))
        #expect(indicator.isVisible(at: ms(2_300)))
    }

    @Test("已經在等的時候再開始一次：不重新計時，已經出現的「準備中」不會消失")
    func beginWhileWaiting() {
        var indicator = DelayedIndicator()
        indicator.begin(at: ms(0))
        indicator.begin(at: ms(200))
        #expect(indicator.revealsAt == ms(300))
        #expect(indicator.isVisible(at: ms(300)))

        indicator.begin(at: ms(400))
        #expect(indicator.isVisible(at: ms(400)))
    }
}
