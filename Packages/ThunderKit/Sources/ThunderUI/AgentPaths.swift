import Foundation
import ThunderCore
import ThunderSession

/// 給 AI agent 的路徑（DESIGN.md 4.3、4.6 節，D34）：現在可以複製哪些路徑。nil 是不能複製，按鈕不出現。
public struct AgentPaths: Sendable, Equatable {
    /// 逐字稿：錄音中是 `live-transcript.txt`，過去錄音是 `transcript.md`。
    public var transcript: URL?
    /// 教材資料夾（`workshop/`）：下載過教材才有。
    public var workshop: URL?
    /// 過去錄音已經搬進 Library，但還沒有標題：命名之後才能複製（沒有標題的場次在摘要做好時會改名）。
    public var waitsForTitle: Bool

    public init(transcript: URL? = nil, workshop: URL? = nil, waitsForTitle: Bool = false) {
        self.transcript = transcript
        self.workshop = workshop
        self.waitsForTitle = waitsForTitle
    }

    /// 錄音中（含暫停）的這一場。
    public static func recording(_ directory: SessionDirectory) -> AgentPaths { AgentPaths() }

    /// 過去錄音的一場：路徑不會再變（已經搬進 Library、有標題）才給。
    public static func finished(_ directory: SessionDirectory, meta: SessionMeta) -> AgentPaths { AgentPaths() }
}
