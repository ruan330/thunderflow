import Testing
import ThunderUI

@Suite("浮動字幕視窗打開時的高度：跟著字級，兩段中文與一段英文放得下")
struct FloatingCaptionsHeightTests {
    @Test("中文 26 點（預設）時高 170 點，和原本一樣")
    func defaultHeight() {
        #expect(FloatingCaptionsStyle.initialHeight(chineseFontSize: 26) == 170)
    }

    @Test("字級變大或變小時，高度照比例跟著變（字大了不會被擠成一行、後面變成「…」）")
    func scalesWithFontSize() {
        #expect(FloatingCaptionsStyle.initialHeight(chineseFontSize: 52) == 340)
        #expect(FloatingCaptionsStyle.initialHeight(chineseFontSize: 31) > 170)
        #expect(FloatingCaptionsStyle.initialHeight(chineseFontSize: 16) < 170)
    }
}
