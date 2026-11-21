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
    ///
    /// 場次資料夾是工作目錄底下一層、含有 `.thunderflow/session.json` 的資料夾；
    /// 只回報 `session.json` 的狀態是 recording、而且沒有人持有鎖的場次。正在錄音的場次持有鎖
    /// （見 `SessionLock`），所以不會被回報；錄音的程式結束（包括當機）之後鎖就釋放了。
    /// 讀不懂的 `session.json`（例如比這一版新的格式）
    /// 不是這一版能復原的場次，也會被忽略。工作目錄不存在時回傳空陣列。
    /// 結果依開始時間排序。
    public static func findInterrupted(in workingRoot: URL) throws -> [InterruptedSession] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        var found: [InterruptedSession] = []
        for name in try fileManager.contentsOfDirectory(atPath: workingRoot.path).sorted() {
            let directory = SessionDirectory(url: workingRoot.appendingPathComponent(name, isDirectory: true))
            guard fileManager.fileExists(atPath: directory.metaURL.path),
                let meta = try? directory.loadMeta(),
                meta.state == .recording,
                !SessionLock.isHeld(directory)
            else { continue }
            let segments = try RecordingFiles.segments(in: directory.audioDirectoryURL)
            found.append(
                InterruptedSession(
                    directory: directory, meta: meta, recordedDuration: RecordingFiles.totalDuration(of: segments),
                    segmentCount: segments.count))
        }
        return found.sorted { lhs, rhs in
            if lhs.meta.startedAt != rhs.meta.startedAt { return lhs.meta.startedAt < rhs.meta.startedAt }
            return lhs.directory.url.path < rhs.directory.url.path
        }
    }

    /// 復原一個場次：依實際救回的錄音長度更新 `session.json`，狀態改為 finalizing 並標記為已復原。
    ///
    /// 錄音長度在復原的當下重新從分段檔讀出（也就是檔案裡實際有的聲音）。
    /// 之後這個場次的狀態不再是 recording，`findInterrupted` 不會再回報它。
    @discardableResult
    public static func recover(_ session: InterruptedSession) throws -> SessionMeta {
        let segments = try RecordingFiles.segments(in: session.directory.audioDirectoryURL)
        var meta = session.meta
        meta.state = .finalizing
        meta.recovered = true
        meta.durationSeconds = RecordingFiles.totalDuration(of: segments)
        try session.directory.saveMeta(meta)
        return meta
    }
}
