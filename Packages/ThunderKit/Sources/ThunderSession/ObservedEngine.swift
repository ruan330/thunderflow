import ThunderCore

/// 包住一個引擎，讓外面（畫面）也看得到它送出的每一個事件。
///
/// 場次自己會取用引擎的事件（寫進日誌）；畫面需要同一批事件來顯示字幕，所以在引擎外面包這一層：
/// 每個事件先交給 `onEvent`，再原封不動往下傳。`onEvent` 在引擎的 task 上被呼叫，必須立即返回
/// （例如只把事件放進另一個串流），不可以做會等待的事，否則會拖慢字幕。錄音路徑不受影響。
public struct ObservedEngine: LiveCaptionEngine {
    private let base: any LiveCaptionEngine
    private let onEvent: @Sendable (CaptionEvent) -> Void

    public init(_ base: any LiveCaptionEngine, onEvent: @escaping @Sendable (CaptionEvent) -> Void) {
        self.base = base
        self.onEvent = onEvent
    }

    public func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent> {
        let events = base.run(audio: audio, config: config)
        let onEvent = onEvent
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    onEvent(event)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            // 下游不再讀（場次放棄引擎）時，把取消往上傳，引擎才會停
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
