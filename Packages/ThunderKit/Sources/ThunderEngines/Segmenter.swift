import Foundation

/// 切段：把轉錄模型一個字一個字送來的英文，切成一段一段送去翻譯。
///
/// 真人演講的一句話常常十幾秒，等整句說完才翻譯太慢；所以翻譯的單位是「段」：
/// 講者兩次停頓之間，或到句號為止（DESIGN.md 5.6.2 節；實測見 M0b 報告 6.4 節）。
///
/// 一段在下列情況確定（`Output.finished`）：
/// 1. **句號**（`.sentenceEnd`）：出現 `.` `?` `!`，而且後面接的是空白，或 `sentenceConfirmation` 內沒有別的字。
///    `1.5` 的小數點、`Dr.` 這類縮寫、`U.S.` 這類字母縮寫不算。中文的 `。` `？` `！` 一出現就算。
/// 2. **停頓**（`.pause`）：`pauseDetected` 之後，文字也安靜了 `quietAfterPause`（停頓之前說的字都到了）。
///    停頓開始後 `pausePatience` 內文字都沒有安靜下來，就放棄這次停頓。這一段不到 `minimumWordsAtPause` 個字時不切。
/// 3. **太長**（`.tooLong`）：超過 `softWordLimit` 個字之後，在下一個逗號處切；到 `hardWordLimit` 個字時直接切。
/// 4. **太久沒有新的字**（`.idle`）：`idleTimeout` 內沒有任何新的文字。
/// 5. **收尾**（`.flush`）：呼叫 `flush`。
///
/// 一段確定之後才到的東西有兩種，都算在上一段：
/// - **晚到的標點**（例如停頓後才出現的句號）：以 `Output.amended` 補上。
/// - **晚到的尾巴**：因為停頓而確定之後，`lateTailWindow` 內又來了不超過 `lateTailWords` 個字、而且句子就此結束
///   （停頓前的最後一個字常常比較晚到）。以 `Output.extended` 併回上一段，上一段要重新翻譯。
///
/// 時間是輸入：所有方法都由呼叫端給「現在」（秒，只增不減），這個型別自己不看時鐘。
/// 每個方法都會先處理已經到期的計時，再處理這次的輸入。
/// 字數的算法：以空白分開、含有字母或數字的才算一個字；中文字每 2 個算一個字。
public struct Segmenter: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// 句號之後這麼久沒有別的字，就確認是句子結束。
        public var sentenceConfirmation: TimeInterval = 0.2
        /// 偵測到停頓之後，文字要安靜這麼久才切（等停頓之前說的字到齊）。
        public var quietAfterPause: TimeInterval = 0.35
        /// 停頓開始後這麼久，文字都沒有安靜下來，就放棄這次停頓。
        public var pausePatience: TimeInterval = 1.5
        /// 因為停頓而切段時，這一段至少要有這麼多字。
        public var minimumWordsAtPause: Int = 3
        /// 超過這麼多字之後，在下一個逗號處切。
        public var softWordLimit: Int = 25
        /// 到這麼多字還沒有任何邊界，直接切。
        public var hardWordLimit: Int = 40
        /// 這麼久沒有新的文字，就把手上的文字當成一段。
        public var idleTimeout: TimeInterval = 2.0
        /// 因為停頓而確定之後，這麼久之內結束的短句算是晚到的尾巴，併回上一段。
        public var lateTailWindow: TimeInterval = 1.5
        /// 晚到的尾巴最多幾個字。
        public var lateTailWords: Int = 2

        public init() {}
    }

    public enum Reason: String, Sendable, Equatable {
        case sentenceEnd, pause, tooLong, idle, flush
    }

    public enum Output: Sendable, Equatable {
        /// 第 `segment` 段新增的文字（原樣，可能以空白開頭）。
        case delta(segment: Int, text: String)
        /// 第 `segment` 段確定了。`text` 是整段的文字（去掉頭尾的空白）。
        case finished(segment: Int, text: String, reason: Reason)
        /// 已經確定的第 `segment` 段補上晚到的標點。`text` 是補上之後整段的文字。不需要重新翻譯。
        case amended(segment: Int, text: String)
        /// 已經確定的第 `segment` 段併入晚到的尾巴。`text` 是併入之後整段的文字，要重新翻譯。
        /// 尾巴原本是以下一段的增量文字送出的；收到這個之後，下一段重新從空的開始（段號不變）。
        case extended(segment: Int, text: String)
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 目前這一段（還沒確定）已經收到的文字，去掉頭尾的空白。
    public var pendingText: String {
        // 尚未實作（M2）
        ""
    }

    /// 下一個計時到期的時間；沒有任何計時在等就是 nil。呼叫端在這個時間呼叫 `advance(to:)`。
    public var nextDeadline: TimeInterval? {
        // 尚未實作（M2）
        nil
    }

    /// 收到一段增量文字。
    public mutating func receive(_ text: String, at now: TimeInterval) -> [Output] {
        // 尚未實作（M2）
        []
    }

    /// 停頓偵測回報了一次停頓。`speechEnd` 是講者停下來的時間，`now` 是偵測到的時間，兩者和文字用同一條時間軸。
    public mutating func pauseDetected(speechEnd: TimeInterval, at now: TimeInterval) -> [Output] {
        // 尚未實作（M2）
        []
    }

    /// 時間前進到 `now`：處理已經到期的計時。
    public mutating func advance(to now: TimeInterval) -> [Output] {
        // 尚未實作（M2）
        []
    }

    /// 收尾：把手上還沒確定的文字當成一段。沒有文字就什麼都不做。之後還可以繼續使用，段號接著編。
    public mutating func flush(at now: TimeInterval) -> [Output] {
        // 尚未實作（M2）
        []
    }
}
