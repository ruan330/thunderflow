/// 浮動字幕視窗的外觀（DESIGN.md 4.4、4.7 節）：背景的不透明度與字級。
public enum FloatingCaptionsStyle {
    /// 背景不透明度的範圍：低於 0.2 時字會和底下的畫面混在一起讀不清楚；1 是完全不透明。
    /// 只有背景跟著變，字不會變淡。
    public static let opacityRange: ClosedRange<Double> = 0.2...1
    /// 沒有設定過時的背景不透明度。
    public static let defaultOpacity = 0.8
    /// 中文字級的範圍。
    public static let fontSizeRange: ClosedRange<Double> = 16...64

    /// 浮動視窗的中文比字幕的字級大這麼多倍（預設 22 點 → 26 點）：浮動視窗疊在別的畫面上，通常離得比較遠。
    private static let chineseScale = 26.0 / 22.0
    /// 雙語時英文是中文的這麼多倍（26 點 → 17 點）。
    private static let englishScale = 0.65

    /// 一組字級（點）。
    public struct FontSizes: Sendable, Equatable {
        public let chinese: Double
        public let english: Double

        public init(chinese: Double, english: Double) {
            self.chinese = chinese
            self.english = english
        }
    }

    /// 設定裡存的不透明度：沒有存過（nil）或不是數字時用預設值，超出範圍時拉回範圍內。
    public static func opacity(stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return defaultOpacity }
        return min(max(stored, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// 打開字幕視窗時的高度（點）：中文 26 點時 170（兩段中文與一段英文），照比例跟著字級變，
    /// 字大了不會被擠成一行、後面變成「…」。之後使用者可以自己調整視窗的大小。
    public static func initialHeight(chineseFontSize: Double) -> Double {
        (170 * chineseFontSize / 26).rounded()
    }

    /// 浮動視窗的字級：跟著字幕的字級（設定頁與即時翻譯頁的「顯示」），取整數點。
    ///
    /// - Parameters:
    ///   - captionFontSize: 字幕的字級（主視窗中文的字級）。
    ///   - englishOnly: 只看英文：英文是主要的字，用中文的字級。
    public static func fontSizes(captionFontSize: Double, englishOnly: Bool) -> FontSizes {
        let scaled = (captionFontSize * chineseScale).rounded()
        let chinese = min(max(scaled, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        return FontSizes(chinese: chinese, english: englishOnly ? chinese : (chinese * englishScale).rounded())
    }
}
