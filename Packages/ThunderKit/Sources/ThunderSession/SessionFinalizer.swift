import Foundation
import ThunderAudio
import ThunderCore

/// 結束處理的步驟（DESIGN.md 5.7 節），依執行的順序。名稱就是記在 `session.json` 的 `completedSteps` 裡的字串。
public enum FinalizationStep: String, CaseIterable, Sendable {
    /// 基本段落：從日誌產生 `blocks.jsonl`。
    case blocks
    /// 基本逐字稿：`transcript.md`。
    case transcript
    /// 合併錄音：`recording.m4a`，確認時長一致後刪除 CAF 分段。
    case audio
    /// 發布：把資料夾從工作目錄搬進 Library。
    case publish
    /// 摘要：`summary.md`；沒有命名的場次用摘要的標題自動命名。需要網路。
    case summary
}

public struct FinalizationOptions: Sendable {
    /// Library 的位置（存放所有場次資料夾的使用者資料夾）。不存在時會自動建立。
    public var libraryRoot: URL
    /// 產生摘要用的文字模型。nil 時略過摘要（不算失敗）。
    public var textModel: (any TextModel)?
    /// 摘要用的模型 ID。
    public var summaryModel: String
    /// 是否自動產生摘要。false 時略過摘要（不算失敗）。
    public var summarize: Bool

    public init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
        textModel = nil
        summaryModel = "gpt-6-luna"
        summarize = true
    }
}

public enum SessionFinalizerError: Error, Equatable {
    /// 這一場還在錄音，或上次沒有正常結束、還沒復原：先呼叫 `RecordingSession.finish()` 或 `SessionRecovery.recover`。
    case stillRecording
    /// 合併出來的 `recording.m4a` 和 CAF 分段的總長不一致（秒）。CAF 分段原封不動，沒有留下 m4a。
    case durationMismatch(recorded: TimeInterval, merged: TimeInterval)
}

/// 結束處理：把剛錄完的場次做成成品（段落、逐字稿、錄音檔），搬進 Library，再產生摘要。
public struct SessionFinalizer: Sendable {
    private let options: FinalizationOptions

    public init(options: FinalizationOptions) {
        self.options = options
    }

    /// 依序執行還沒記在 `completedSteps` 裡的步驟，回傳場次資料夾最後的位置（在 Library 裡）。
    /// 每處理完一步：先記進 `session.json`，再呼叫 `onProgress`，帶入這一步與場次資料夾當下的位置。
    @discardableResult
    public func finalize(
        _ directory: SessionDirectory,
        onProgress: (@Sendable (FinalizationStep, SessionDirectory) -> Void)? = nil
    ) async throws -> SessionDirectory {
        // 尚未實作（M3）
        directory
    }
}
