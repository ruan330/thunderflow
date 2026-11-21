import Foundation

public struct EngineConfig: Sendable, Equatable {
    public var sourceLanguage: String
    public var targetLanguage: String

    public init(sourceLanguage: String = "en", targetLanguage: String = "zh-TW") {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// 即時字幕引擎：吃音訊串流，吐字幕事件串流。
///
/// 約定：
/// - `audio` 是有上限的等待區。引擎消化太慢時，最舊的音訊會被丟掉並由場次記成缺口；
///   引擎不需要、也沒有辦法讓送音訊的一方等待，所以引擎再怎麼壞都不會拖住錄音。
/// - `audio` 結束代表正常收尾：引擎送完剩下的輸出後，結束回傳的事件串流。
/// - 音訊中斷一段時間（例如使用者暫停）時，引擎自行收尾並關閉連線；音訊恢復時自行重新連線。
/// - 回傳的事件串流被取消時，引擎必須盡快停止。
public protocol LiveCaptionEngine: Sendable {
    func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent>
}
