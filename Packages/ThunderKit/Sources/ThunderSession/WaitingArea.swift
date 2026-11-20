import Synchronization
import ThunderCore

/// 送給引擎的等待區：有上限的 `AsyncStream`（滿了就丟掉最舊的一包），並記下引擎實際取走了多少。
///
/// 引擎拿到的不是等待區本身，而是包在外面的另一個 `AsyncStream`（`engineStream()`）：
/// 引擎每取一包，先算進「已取走」再交給它。等待區丟掉的、引擎取走的，都是當時最舊的那一包，
/// 所以還留在等待區裡的一定是最新、連續的一段：從「被擠掉的＋被取走的」那個位置，到最後放進去的那一包為止。
///
/// 送音訊的一方可以隨時「放棄」等待區（引擎已經結束或被放棄）：放棄之後引擎再也拿不到裡面的音訊，
/// 而放棄的那一刻引擎取走了多少是確定的，所以每一包不是被引擎取走，就是由場次記成缺口，不會兩邊都算、也不會漏掉。
///
/// 執行緒：`yield`、`finish`、`abandon` 只由送音訊的一方呼叫（場次的錄音路徑或結束流程，彼此不會同時進行）；
/// `engineStream()` 交出去的串流只能有一個取用者（引擎），這也是 `AsyncStream` 本身的規定。
final class WaitingArea: @unchecked Sendable {
    // @unchecked Sendable：`continuation` 本身是 thread-safe 的；`iterator` 只在引擎那一側使用，
    // 而 `AsyncStream(unfolding:)` 對單一取用者是一次呼叫一個 produce，所以不會同時被兩條執行緒修改；
    // `consumedFrames` 是 Atomic，是兩側之間唯一共用的可變狀態。
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private var iterator: AsyncStream<AudioChunk>.Iterator
    /// 引擎取走的樣本數（引擎的取樣率）；`abandonedMarker` 表示已經放棄。只有引擎那一側會增加它。
    private let consumedFrames = Atomic<Int64>(0)
    private static let abandonedMarker: Int64 = -1

    /// - Parameter capacity: 最多放幾包，滿了就丟掉最舊的一包。
    init(capacity: Int) {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(capacity))
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    /// 放進一包。一律立即返回；`.dropped` 帶回被擠掉的那一包（最舊的）。
    func yield(_ chunk: AudioChunk) -> AsyncStream<AudioChunk>.Continuation.YieldResult {
        continuation.yield(chunk)
    }

    /// 音訊結束：引擎取完剩下的音訊後，它的串流就會結束。
    func finish() {
        continuation.finish()
    }

    /// 交給引擎的音訊串流。只能交給一個取用者。
    func engineStream() -> AsyncStream<AudioChunk> {
        AsyncStream(unfolding: { [self] in await take() })
    }

    /// 放棄等待區，回傳到這一刻為止引擎取走的樣本數；之後引擎再也拿不到等待區裡的音訊。
    /// 重複放棄回傳 nil（那時剩下的音訊已經算過了）。
    func abandon() -> Int64? {
        let consumed = consumedFrames.exchange(Self.abandonedMarker, ordering: .acquiringAndReleasing)
        return consumed == Self.abandonedMarker ? nil : consumed
    }

    /// 引擎取下一包：先算進「已取走」再交出去。等待區已經被放棄的話，這一包已經記成缺口，不再交給引擎。
    private func take() async -> AudioChunk? {
        guard let chunk = await iterator.next() else { return nil }
        var consumed = consumedFrames.load(ordering: .relaxed)
        while consumed != Self.abandonedMarker {
            let (exchanged, current) = consumedFrames.compareExchange(
                expected: consumed, desired: consumed + Int64(chunk.frameCount), ordering: .acquiringAndReleasing)
            if exchanged { return chunk }
            consumed = current
        }
        return nil
    }
}
