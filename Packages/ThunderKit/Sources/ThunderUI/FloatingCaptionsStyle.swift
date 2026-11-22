/// 浮動字幕視窗的外觀（DESIGN.md 4.4、4.7 節）：背景的不透明度與字級。
public enum FloatingCaptionsStyle {
    /// 背景不透明度的範圍。
    public static let opacityRange: ClosedRange<Double> = 0.2...1
    /// 沒有設定過時的背景不透明度。
    public static let defaultOpacity = 0.8
    /// 中文字級的範圍。
    public static let fontSizeRange: ClosedRange<Double> = 16...64

    /// 一組字級（點）。
    public struct FontSizes: Sendable, Equatable {
        public let chinese: Double
        public let english: Double

        public init(chinese: Double, english: Double) {
            self.chinese = chinese
            self.english = english
        }
    }

    /// 設定裡存的不透明度。
    public static func opacity(stored: Double?) -> Double {
        // 暫時照目前的做法（不檢查範圍），測試會指出問題；實作時改掉
        stored ?? defaultOpacity
    }

    /// 浮動視窗的字級。
    public static func fontSizes(captionFontSize: Double, englishOnly: Bool) -> FontSizes {
        // 暫時照目前的做法（固定 26 與 17），測試會指出問題；實作時改掉
        FontSizes(chinese: 26, english: 17)
    }
}
