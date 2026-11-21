import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public struct CaptionBoard: Sendable, Equatable {
    /// 已經確定的一段。
    public struct Line: Sendable, Equatable, Identifiable {
        /// 段號。
        public var id: Int
        public var english: String
        /// 中文定稿；還沒有時是空字串。
        public var chinese: String
        /// 定稿到之前先顯示的暫定譯文；定稿到了就清掉，不再出現。
        public var provisional: String
        /// 確定不會有定稿了（翻譯失敗，或引擎已經結束）。結束後由精修補上。
        public var untranslated: Bool
        /// 這一段確定時的音訊時間。
        public var at: AudioTime
    }

    public private(set) var lines: [Line] = []
    public private(set) var liveSegment: Int?
    public private(set) var liveEnglish = ""
    public private(set) var liveChinese = ""

    public init() {}
    public mutating func apply(_ event: CaptionEvent) {}
    public mutating func engineEnded() {}
    public func chinese(for line: Line, showingProvisional: Bool) -> String { "" }
}
