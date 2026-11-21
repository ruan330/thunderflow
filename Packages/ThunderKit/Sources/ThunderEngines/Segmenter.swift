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

    // 目前這一段
    private var segment = 0
    private var pending = ""
    /// `pending` 裡有沒有真正的內容（字母、數字或中文字）。只有空白與開頭的引號時是 false。
    private var pendingHasContent = false
    private var lastTextAt: TimeInterval = 0
    /// 等確認的句號出現的時間。句號（連同後面的引號、括號）一定在 `pending` 的最後。
    private var sentenceCandidateAt: TimeInterval?
    private var pause: (speechEnd: TimeInterval, detectedAt: TimeInterval)?
    /// 上一段：晚到的標點與尾巴要接在它後面。
    private var previous: (segment: Int, text: String, reason: Reason, finishedAt: TimeInterval)?
    private var clock: TimeInterval = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 目前這一段（還沒確定）已經收到的文字，去掉頭尾的空白。
    public var pendingText: String {
        pending.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 下一個計時到期的時間；沒有任何計時在等就是 nil。呼叫端在這個時間呼叫 `advance(to:)`。
    public var nextDeadline: TimeInterval? {
        nextTimer()?.due
    }

    /// 收到一段增量文字。
    public mutating func receive(_ text: String, at now: TimeInterval) -> [Output] {
        var outputs = advance(to: now)
        var delta = ""

        func flushDelta(_ outputs: inout [Output], _ delta: inout String, segment: Int) {
            if !delta.isEmpty { outputs.append(.delta(segment: segment, text: delta)) }
            delta = ""
        }

        for character in text {
            // 這一段還沒有任何內容時，先到的收尾標點屬於上一段
            if !pendingHasContent, Self.trailingPunctuation.contains(character) {
                if var last = previous {
                    last.text.append(character)
                    previous = last
                    outputs.append(.amended(segment: last.segment, text: last.text))
                }
                continue
            }

            if sentenceCandidateAt != nil {
                if Self.closers.contains(character) {
                    // 引號、括號跟著句號，仍然屬於這一句
                } else if character.isWhitespace {
                    flushDelta(&outputs, &delta, segment: segment)
                    finish(.sentenceEnd, &outputs)
                } else {
                    sentenceCandidateAt = nil  // 例如 1.5 的小數點
                }
            } else if character.isWhitespace, pendingHasContent, !(pending.last?.isWhitespace ?? true) {
                // 一個字剛結束：檢查長度
                let words = Self.wordCount(pending)
                let endsWithComma = pending.last.map { Self.commas.contains($0) } ?? false
                if words >= Double(configuration.hardWordLimit)
                    || (endsWithComma && words >= Double(configuration.softWordLimit))
                {
                    flushDelta(&outputs, &delta, segment: segment)
                    finish(.tooLong, &outputs)
                }
            }

            pending.append(character)
            delta.append(character)
            if !character.isWhitespace {
                lastTextAt = clock
                if character.isLetter || character.isNumber { pendingHasContent = true }
            }

            if Self.wideTerminators.contains(character) {
                // 中文的句號不會和小數點、縮寫混淆
                flushDelta(&outputs, &delta, segment: segment)
                finish(.sentenceEnd, &outputs)
            } else if Self.wideCommas.contains(character), Self.wordCount(pending) >= Double(configuration.softWordLimit) {
                flushDelta(&outputs, &delta, segment: segment)
                finish(.tooLong, &outputs)
            } else if Self.terminators.contains(character), pendingHasContent {
                sentenceCandidateAt = (character == "." && Self.endsWithAbbreviation(pending)) ? nil : clock
            }
        }
        flushDelta(&outputs, &delta, segment: segment)
        return outputs
    }

    /// 停頓偵測回報了一次停頓。`speechEnd` 是講者停下來的時間，`now` 是偵測到的時間，兩者和文字用同一條時間軸。
    public mutating func pauseDetected(speechEnd: TimeInterval, at now: TimeInterval) -> [Output] {
        var outputs = advance(to: now)
        pause = (speechEnd: speechEnd, detectedAt: clock)
        outputs += advance(to: now)
        return outputs
    }

    /// 時間前進到 `now`：處理已經到期的計時。
    public mutating func advance(to now: TimeInterval) -> [Output] {
        clock = max(clock, now)
        var outputs: [Output] = []
        while let timer = nextTimer(), timer.due <= clock {
            switch timer.kind {
            case .sentence:
                finish(.sentenceEnd, &outputs)
            case .pause:
                if Self.wordCount(pending) >= Double(configuration.minimumWordsAtPause) {
                    finish(.pause, &outputs)
                }
                pause = nil
            case .idle:
                finish(.idle, &outputs)
            }
        }
        expirePauseIfNeeded()
        return outputs
    }

    /// 收尾：把手上還沒確定的文字當成一段。沒有文字就什麼都不做。之後還可以繼續使用，段號接著編。
    public mutating func flush(at now: TimeInterval) -> [Output] {
        var outputs = advance(to: now)
        if pendingHasContent {
            finish(.flush, &outputs)
        } else {
            pending = ""
        }
        return outputs
    }

    // MARK: 計時

    private enum TimerKind { case sentence, pause, idle }

    /// 最早到期的那一個計時。
    private func nextTimer() -> (kind: TimerKind, due: TimeInterval)? {
        guard pendingHasContent else { return nil }
        var timers: [(kind: TimerKind, due: TimeInterval)] = []
        if let candidateAt = sentenceCandidateAt {
            timers.append((.sentence, candidateAt + configuration.sentenceConfirmation))
        }
        if let pause, lastTextAt <= pause.speechEnd + configuration.pausePatience {
            timers.append((.pause, max(lastTextAt + configuration.quietAfterPause, pause.detectedAt)))
        }
        timers.append((.idle, lastTextAt + configuration.idleTimeout))
        return timers.min { $0.due < $1.due }
    }

    /// 停頓開始後太久，文字都沒有安靜下來（或一直沒有字）：放棄這次停頓。
    private mutating func expirePauseIfNeeded() {
        guard let current = pause else { return }
        let limit = current.speechEnd + configuration.pausePatience
        if pendingHasContent ? lastTextAt > limit : clock > limit + configuration.quietAfterPause {
            pause = nil
        }
    }

    // MARK: 段

    private mutating func finish(_ reason: Reason, _ outputs: inout [Output]) {
        let text = pendingText
        if pendingHasContent {
            if reason == .sentenceEnd, var last = previous, last.reason == .pause,
                clock - last.finishedAt <= configuration.lateTailWindow,
                Self.wordCount(pending) <= Double(configuration.lateTailWords)
            {
                // 停頓前的最後一兩個字晚到了：併回剛確定的那一段
                last.text += " " + text
                last.reason = .sentenceEnd
                previous = last
                outputs.append(.extended(segment: last.segment, text: last.text))
            } else {
                outputs.append(.finished(segment: segment, text: text, reason: reason))
                previous = (segment: segment, text: text, reason: reason, finishedAt: clock)
                segment += 1
            }
        }
        pending = ""
        pendingHasContent = false
        sentenceCandidateAt = nil
    }

    // MARK: 字元的分類

    private static let terminators: Set<Character> = [".", "?", "!"]
    private static let wideTerminators: Set<Character> = ["。", "？", "！"]
    private static let commas: Set<Character> = [",", ";", ":"]
    private static let wideCommas: Set<Character> = ["，", "；", "：", "、"]
    /// 跟在句號後面、仍然屬於同一句的引號與括號。
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "」", "』"]
    /// 出現在一段的開頭時，其實屬於上一段的標點。
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "。", "，", "；", "：", "？", "！", "、", "”", "’", ")", "]", "}", "」", "』", "…",
    ]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "st", "jr", "sr", "inc", "ltd"]

    /// `text` 以句點結尾。句點前面的那個字是不是縮寫（`Dr.`）或字母縮寫（`U.S.`、`e.g.`）。
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let body = text.dropLast()
        guard let token = body.split(whereSeparator: \.isWhitespace).last else { return false }
        let word = token.drop { !$0.isLetter && !$0.isNumber }.lowercased()
        if abbreviations.contains(word) { return true }
        // 每一節都只有一個字母：U、U.S、e.g
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { $0.count == 1 && ($0.first?.isLetter ?? false) }
    }

    /// 字數：以空白分開、含有字母或數字的算一個字；中文字每 2 個算一個字。
    private static func wordCount(_ text: String) -> Double {
        var total = 0.0
        for token in text.split(whereSeparator: \.isWhitespace) {
            var ideographs = 0
            var hasOther = false
            for character in token {
                if isIdeograph(character) {
                    ideographs += 1
                } else if character.isLetter || character.isNumber {
                    hasOther = true
                }
            }
            total += Double(ideographs) / 2 + (hasOther ? 1 : 0)
        }
        return total
    }

    private static func isIdeograph(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
