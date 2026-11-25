import Foundation
import ThunderCore
import ThunderSession

/// 給 AI agent 的路徑（DESIGN.md 4.3、4.6 節，D34）：現在可以複製哪些路徑。nil 是不能複製，按鈕不出現。
///
/// 過去錄音的路徑要等不會再變才給：搬進 Library 之前、自動命名之前（沒有標題的場次在摘要做好時會改名），
/// 複製到的路徑過一下子就失效了。
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

    /// 錄音中（含暫停）的這一場：錄音中資料夾不會搬，也不會改名。
    public static func recording(_ directory: SessionDirectory) -> AgentPaths {
        AgentPaths(
            transcript: existing(directory.liveTranscriptURL),
            workshop: hasMaterials(directory) ? directory.workshopURL : nil)
    }

    /// 過去錄音的一場：路徑不會再變（已經搬進 Library、有標題）才給。之後只有使用者自己改名時路徑才會變。
    public static func finished(_ directory: SessionDirectory, meta: SessionMeta) -> AgentPaths {
        guard meta.completedSteps.contains(FinalizationStep.publish.rawValue) else { return AgentPaths() }
        guard !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentPaths(waitsForTitle: true)
        }
        return AgentPaths(
            transcript: existing(directory.transcriptURL),
            workshop: hasMaterials(directory) ? directory.workshopURL : nil)
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 下載過教材：`workshop/` 裡至少有一個不是隱藏的東西（下載完成才搬進來，所以有就是完整的）。
    private static func hasMaterials(_ directory: SessionDirectory) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.workshopURL.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }
}
