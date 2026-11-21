import Foundation
import ThunderAudio
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public final class LiveRecording: @unchecked Sendable {
    public struct Options: Sendable {
        public var source: CaptureSource
        public var title = ""
        public var event = ""
        public var speaker = ""
        public var keywords: [String] = []
        /// 引擎的名稱，記在 `session.json`。
        public var engineName = ""
        /// 工作目錄：錄音中的場次資料夾放在這裡。
        public var workingRoot: URL
        /// 結束時最多等引擎把最後幾段翻完多久。
        public var engineDrainTimeout: Duration = .seconds(10)

        public init(source: CaptureSource, workingRoot: URL) {
            self.source = source
            self.workingRoot = workingRoot
        }
    }

    public let id = UUID()
    public let directory: SessionDirectory
    public var onSourceEnded: (@Sendable () -> Void)?

    public init(options: Options, engine: any LiveCaptionEngine, onEvent: @escaping @Sendable (CaptionEvent) -> Void) {
        directory = SessionDirectory(url: options.workingRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    public var sourceDescription: String { "" }
    public var audioTime: AudioTime { .zero }
    public var isPaused: Bool { false }
    public var level: Float { 0 }
    public var captureCallbackCount: Int { 0 }
    public func start() throws {}
    public func pause() {}
    public func resume() {}
    public func mark() {}
    @discardableResult
    public func stop() async throws -> SessionMeta { throw RecordingSessionError.alreadyFinished }
}
