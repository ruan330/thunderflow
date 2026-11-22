import Testing
import ThunderUI

@Suite("浮動字幕的外觀：背景的不透明度有範圍，字級跟著字幕的字級")
struct FloatingCaptionsStyleTests {
    @Test("沒有設定過背景的不透明度：用預設的 0.8")
    func defaultOpacity() {
        #expect(FloatingCaptionsStyle.opacity(stored: nil) == 0.8)
        #expect(FloatingCaptionsStyle.defaultOpacity == 0.8)
    }

    @Test("存的不透明度在範圍內：照用")
    func opacityInRange() {
        for value in [0.2, 0.55, 1] {
            #expect(FloatingCaptionsStyle.opacity(stored: value) == value)
        }
    }

    @Test("存的不透明度超出範圍：拉回 0.2 到 1（太透明時字會和底下的畫面混在一起）；不是數字時用預設值")
    func opacityOutOfRange() {
        #expect(FloatingCaptionsStyle.opacityRange == 0.2...1)
        #expect(FloatingCaptionsStyle.opacity(stored: 0) == 0.2)
        #expect(FloatingCaptionsStyle.opacity(stored: -3) == 0.2)
        #expect(FloatingCaptionsStyle.opacity(stored: 1.5) == 1)
        #expect(FloatingCaptionsStyle.opacity(stored: .nan) == 0.8)
        #expect(FloatingCaptionsStyle.opacity(stored: .infinity) == 0.8)
    }

    @Test("字級跟著字幕的字級：預設的 22 點時，中文 26 點、英文 17 點（和原本一樣）")
    func defaultFontSizes() {
        #expect(
            FloatingCaptionsStyle.fontSizes(captionFontSize: 22, englishOnly: false)
                == FloatingCaptionsStyle.FontSizes(chinese: 26, english: 17))
    }

    @Test("字幕的字級調大或調小：浮動字幕跟著變大變小，中文不小於 16 點、不大於 64 點")
    func followsCaptionFontSize() {
        let small = FloatingCaptionsStyle.fontSizes(captionFontSize: 14, englishOnly: false)
        let large = FloatingCaptionsStyle.fontSizes(captionFontSize: 48, englishOnly: false)
        #expect(small.chinese < 26 && small.english < 17)
        #expect(large.chinese > 26 && large.english > 17)
        #expect(FloatingCaptionsStyle.fontSizeRange == 16...64)
        #expect(FloatingCaptionsStyle.fontSizes(captionFontSize: 4, englishOnly: false).chinese == 16)
        #expect(FloatingCaptionsStyle.fontSizes(captionFontSize: 200, englishOnly: false).chinese == 64)
    }

    @Test("只看英文：英文用中文的字級（英文是主要的字）")
    func englishOnly() {
        let sizes = FloatingCaptionsStyle.fontSizes(captionFontSize: 22, englishOnly: true)
        #expect(sizes.english == sizes.chinese)
        #expect(sizes.chinese == 26)
    }
}
