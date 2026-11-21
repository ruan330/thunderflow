import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public struct TranscribeTranslateEngine: LiveCaptionEngine {
    public struct Configuration: Sendable {
        /// 轉錄連線的網址。網址不帶模型，模型在設定訊息裡。
        public var endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        public var link = TranscriptionLink.Configuration()
        public var translation = TranslationPlanner.Configuration()
        public var pause = PauseDetector.Configuration()
        public var segmenter = Segmenter.Configuration()
        /// 一條連線上等著送出的訊息超過這麼多則，就當成連線卡住了，關掉重連（每則約 200 ms 的音訊）。
        public var stalledOutboxLimit = 100

        public init() {}
    }

    public init(
        configuration: Configuration = Configuration(),
        apiKey: String,
        connector: any RealtimeConnector = URLSessionRealtimeConnector(),
        textModel: any TextModel
    ) {}

    public func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent> {
        AsyncStream { $0.finish() }
    }
}
