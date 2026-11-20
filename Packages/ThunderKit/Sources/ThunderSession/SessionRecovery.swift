import Foundation
import ThunderAudio
import ThunderCore

/// 上次沒有正常結束的場次。
public struct InterruptedSession: Sendable, Equatable {
    public var directory: SessionDirectory
    public var meta: SessionMeta
    /// 檔案裡實際救得回來的錄音長度（秒）。
    public var recordedDuration: TimeInterval
    public var segmentCount: Int

    public init(directory: SessionDirectory, meta: SessionMeta, recordedDuration: TimeInterval, segmentCount: Int) {
        self.directory = directory
        self.meta = meta
        self.recordedDuration = recordedDuration
        self.segmentCount = segmentCount
    }
}

/// 當機復原：App 啟動時找出狀態還停在 recording 的場次，把它們接回正常的結束流程。
public enum SessionRecovery {
    /// 找出工作目錄裡沒有正常結束的場次。不是場次資料夾的東西會被忽略。
    public static func findInterrupted(in workingRoot: URL) throws -> [InterruptedSession] {
        throw NotYetImplemented("SessionRecovery.findInterrupted(in:)")
    }

    /// 復原一個場次：依實際救回的錄音長度更新 `session.json`，狀態改為 finalizing 並標記為已復原。
    @discardableResult
    public static func recover(_ session: InterruptedSession) throws -> SessionMeta {
        throw NotYetImplemented("SessionRecovery.recover(_:)")
    }
}
