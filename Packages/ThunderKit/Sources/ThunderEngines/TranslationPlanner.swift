import Foundation
import ThunderCore

/// 翻譯排程：決定什麼時候把哪一段英文送去翻譯，以及譯文什麼時候可以送出（DESIGN.md 5.6.2 節「翻譯」）。
///
/// 和 `TranscriptionLink` 一樣只做決定，不碰網路：呼叫端告訴它發生了什麼（一段英文確定了、進行中的文字變長了、
/// 某個請求有了輸出、完成或失敗、時間到了），它回傳要做的事（送出請求、取消請求、送出譯文）。
/// 時間是輸入（秒，只增不減）。
///
/// **定稿**（每段一次，會存檔）：
/// - 一段英文確定就送出請求，帶前幾段英文當上下文。多段可以同時翻譯，但**依段的順序送出**：
///   後面的段先翻好，也要等前面的段有結果（翻好或放棄）才送。
/// - 請求送出後 `hedgeAfter` 內沒有收到任何輸出，就再送一個相同的請求，先回來的為準。
/// - `giveUpAfter` 都沒有結果就放棄這一段：不送定稿，後面的段照常送。失敗的請求在期限內會重試。
/// - 譯文出現簡體字時重試一次（要求只用繁體字）；重試也失敗就用第一次的結果。
/// - 一段併入晚到的尾巴（`segmentExtended`）時重新翻譯；第一次的定稿如果已經送出，新的定稿會再送一次。
///
/// **暫定譯文**（只給畫面，不存檔，可以關閉）：
/// - 進行中的這一段每多 `provisionalWords` 個字、而且距離上一次請求至少 `provisionalInterval`，就把目前的文字送去翻譯。
/// - 同一時間只有一個暫定譯文的請求：它回來之後才送下一個（那時用的是最新的文字），中間的版本直接跳過。
///   這樣文字模型變慢時，請求不會互相取消到一個都回不來。請求超過 `provisionalTimeout` 沒有回來就取消。
/// - 一段的第一個暫定譯文邊收邊送（畫面上原本沒有字，逐字出現不會閃）；之後的版本等完整回來才整段取代。
/// - 這一段確定之後，還沒回來的暫定譯文直接取消，定稿會取代它。
public struct TranslationPlanner: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var model: String = "gpt-6-luna"
        /// 是否產生暫定譯文。
        public var provisional: Bool = true
        public var provisionalWords: Int = 3
        public var provisionalInterval: TimeInterval = 1
        public var provisionalTimeout: TimeInterval = 4
        public var hedgeAfter: TimeInterval = 3
        public var giveUpAfter: TimeInterval = 8
        /// 一段最多送出幾個請求（含重試與備援）。
        public var maximumAttempts: Int = 3
        /// 帶前幾段英文當上下文。
        public var contextSegments: Int = 2
        /// 場次資訊與關鍵詞：放進提示，讓專有名詞保留原文。
        public var title: String = ""
        public var event: String = ""
        public var speaker: String = ""
        public var keywords: [String] = []

        public init() {}
    }

    public enum Effect: Sendable, Equatable {
        /// 送出一個請求，編號是 `request`。之後這個請求的輸出、完成、失敗都帶這個編號回報。
        case start(request: Int, TextRequest)
        /// 取消一個還沒完成的請求。取消之後不需要再回報它的結果。
        case cancel(request: Int)
        /// 第 `segment` 段的中文定稿。
        case translation(segment: Int, text: String)
        /// 第 `segment` 段到目前為止的暫定譯文（整段取代上一次的）。
        case provisional(segment: Int, text: String)
    }

    private enum Outcome: Equatable {
        case translated(String)
        case failed
    }

    private enum Purpose: Equatable {
        case final(segment: Int)
        case provisional(segment: Int)
    }

    /// 一段的定稿。
    private struct Final {
        var english: String
        var context: [String]
        var startedAt: TimeInterval
        var inFlight: Set<Int> = []
        var attempts = 0
        var hedged = false
        var gotOutput = false
        /// 已經因為簡體字重試過。
        var strict = false
        /// 含有簡體字的第一次結果；重試失敗時用它。
        var fallback: String?
        /// nil：還在等結果。
        var outcome: Outcome?
        /// 定稿已經送出過（或已經放棄）。之後如果重新翻譯，新的結果直接再送一次。
        var emitted = false
    }

    /// 進行中的這一段（暫定譯文）。
    private struct Live {
        var segment: Int?
        var text = ""
        var words = 0.0
        /// 上一次請求送出時的字數與時間。
        var requestedWords = 0.0
        var requestedAt = -Double.infinity
        var inFlight: (request: Int, startedAt: TimeInterval)?
        /// 這一段已經有完整的暫定譯文顯示在畫面上。
        var shown = false
        /// 最近一次送出的暫定譯文：內容沒有變就不重複送。
        var emitted = ""
    }

    public let configuration: Configuration

    private var finals: [Int: Final] = [:]
    /// 還沒送出定稿的段，依確定的順序。
    private var queue: [Int] = []
    private var requests: [Int: Purpose] = [:]
    private var nextRequest = 0
    /// 最近確定的幾段英文，當下一段的上下文。
    private var history: [(segment: Int, text: String)] = []
    private var live = Live()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 是否還有定稿在等結果。收尾時要等它變成 false。
    public var hasPendingFinals: Bool {
        finals.values.contains { $0.outcome == nil }
    }

    /// 下一個需要呼叫 `advance(to:)` 的時間；沒有就是 nil。
    public var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        for final in finals.values where final.outcome == nil {
            deadlines.append(final.startedAt + configuration.giveUpAfter)
            if !final.hedged, !final.gotOutput { deadlines.append(final.startedAt + configuration.hedgeAfter) }
        }
        if let inFlight = live.inFlight { deadlines.append(inFlight.startedAt + configuration.provisionalTimeout) }
        return deadlines.min()
    }

    // MARK: 輸入

    /// 第 `segment` 段的英文確定了。
    public mutating func segmentFinished(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        effects += endProvisional()
        // 已經送出、不會再變動的段可以丟掉了（晚到的尾巴只會併進最近確定的那一段）
        finals = finals.filter { !($0.value.emitted && $0.value.outcome != nil) }
        let context = history.suffix(configuration.contextSegments).map(\.text)
        history.append((segment, text))
        if history.count > configuration.contextSegments + 1 { history.removeFirst(history.count - configuration.contextSegments - 1) }
        finals[segment] = Final(english: text, context: context, startedAt: now)
        queue.append(segment)
        effects += startAttempt(for: segment)
        return effects
    }

    /// 第 `segment` 段（最近確定的那一段）併入了晚到的尾巴，`text` 是併入之後整段的英文：重新翻譯。
    public mutating func segmentExtended(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        // 尾巴原本算在下一段，那一段現在重新開始
        effects += endProvisional()
        if let index = history.lastIndex(where: { $0.segment == segment }) { history[index].text = text }
        guard var final = finals[segment] else {
            return effects + segmentFinished(segment, text: text, at: now)
        }
        for request in final.inFlight.sorted() {
            effects.append(.cancel(request: request))
            requests[request] = nil
        }
        final = Final(english: text, context: final.context, startedAt: now, emitted: final.emitted)
        finals[segment] = final
        effects += startAttempt(for: segment)
        return effects
    }

    /// 進行中的第 `segment` 段目前的英文（還沒確定）。每次文字變長就呼叫。
    public mutating func pendingText(_ text: String, segment: Int, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard configuration.provisional else { return effects }
        if live.segment != segment {
            effects += endProvisional()
            live.segment = segment
        }
        live.text = text
        live.words = Words.count(text)
        effects += startProvisionalIfDue(at: now)
        return effects
    }

    /// 第 `request` 個請求到目前為止收到的輸出（累計的全文）。
    public mutating func progress(request: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        let output = Self.cleaned(text)
        guard !output.isEmpty, let purpose = requests[request] else { return effects }
        switch purpose {
        case .final(let segment):
            finals[segment]?.gotOutput = true
        case .provisional(let segment):
            // 這一段的第一個暫定譯文邊收邊送；之後的版本等完整回來才取代，免得畫面上的字先縮短再變長
            if segment == live.segment, !live.shown, output != live.emitted {
                live.emitted = output
                effects.append(.provisional(segment: segment, text: output))
            }
        }
        return effects
    }

    /// 第 `request` 個請求完成了，`text` 是完整的輸出。
    public mutating func completed(request: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard let purpose = requests.removeValue(forKey: request) else { return effects }
        let output = Self.cleaned(text)
        switch purpose {
        case .final(let segment):
            guard var final = finals[segment], final.outcome == nil else { break }
            final.inFlight.remove(request)
            finals[segment] = final
            if output.isEmpty {
                effects += attemptEnded(for: segment, at: now)
            } else if ChineseScript.containsSimplified(output), !final.strict {
                // 出現簡體字：重試一次，這一次明確要求只用繁體字
                for other in final.inFlight.sorted() {
                    effects.append(.cancel(request: other))
                    requests[other] = nil
                }
                final.inFlight = []
                final.strict = true
                final.fallback = output
                finals[segment] = final
                effects += startAttempt(for: segment)
            } else {
                effects += resolve(segment, .translated(output))
            }
        case .provisional(let segment):
            guard live.inFlight?.request == request else { break }
            live.inFlight = nil
            if segment == live.segment {
                if !output.isEmpty {
                    if output != live.emitted {
                        live.emitted = output
                        effects.append(.provisional(segment: segment, text: output))
                    }
                    live.shown = true
                }
                effects += startProvisionalIfDue(at: now)
            }
        }
        return effects
    }

    /// 第 `request` 個請求失敗了。
    public mutating func failed(request: Int, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard let purpose = requests.removeValue(forKey: request) else { return effects }
        switch purpose {
        case .final(let segment):
            finals[segment]?.inFlight.remove(request)
            effects += attemptEnded(for: segment, at: now)
        case .provisional:
            if live.inFlight?.request == request { live.inFlight = nil }
        }
        return effects
    }

    /// 時間前進到 `now`：處理到期的事（備援請求、放棄、暫定譯文逾時）。
    public mutating func advance(to now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        for segment in finals.keys.sorted() {
            guard let final = finals[segment], final.outcome == nil else { continue }
            if now >= final.startedAt + configuration.giveUpAfter {
                effects += resolve(segment, final.fallback.map { .translated($0) } ?? .failed)
            } else if !final.hedged, !final.gotOutput, now >= final.startedAt + configuration.hedgeAfter {
                finals[segment]?.hedged = true
                if final.attempts < configuration.maximumAttempts { effects += startAttempt(for: segment) }
            }
        }
        if let inFlight = live.inFlight, now >= inFlight.startedAt + configuration.provisionalTimeout {
            effects.append(.cancel(request: inFlight.request))
            requests[inFlight.request] = nil
            live.inFlight = nil
            effects += startProvisionalIfDue(at: now)
        }
        return effects
    }

    // MARK: 定稿

    private mutating func startAttempt(for segment: Int) -> [Effect] {
        guard var final = finals[segment] else { return [] }
        let request = nextRequest
        nextRequest += 1
        final.inFlight.insert(request)
        final.attempts += 1
        finals[segment] = final
        requests[request] = .final(segment: segment)
        return [.start(request: request, makeRequest(text: final.english, context: final.context, isFinal: true, strict: final.strict))]
    }

    /// 一個請求沒有結果（失敗或輸出是空的）：還有別的請求在跑就等它；否則在期限內重試，不然就放棄。
    private mutating func attemptEnded(for segment: Int, at now: TimeInterval) -> [Effect] {
        guard let final = finals[segment], final.outcome == nil, final.inFlight.isEmpty else { return [] }
        if final.attempts < configuration.maximumAttempts, now < final.startedAt + configuration.giveUpAfter {
            return startAttempt(for: segment)
        }
        return resolve(segment, final.fallback.map { .translated($0) } ?? .failed)
    }

    private mutating func resolve(_ segment: Int, _ outcome: Outcome) -> [Effect] {
        guard var final = finals[segment] else { return [] }
        var effects: [Effect] = []
        for request in final.inFlight.sorted() {
            effects.append(.cancel(request: request))
            requests[request] = nil
        }
        final.inFlight = []
        final.outcome = outcome
        let reissue = final.emitted
        finals[segment] = final
        if reissue {
            // 重新翻譯的結果：這一段已經輪過了，直接再送一次
            if case .translated(let text) = outcome { effects.append(.translation(segment: segment, text: text)) }
        } else {
            effects += flushQueue()
        }
        return effects
    }

    /// 依順序送出已經有結果的定稿，遇到還在等的就停。
    private mutating func flushQueue() -> [Effect] {
        var effects: [Effect] = []
        while let segment = queue.first, let final = finals[segment], let outcome = final.outcome {
            if case .translated(let text) = outcome { effects.append(.translation(segment: segment, text: text)) }
            finals[segment]?.emitted = true
            queue.removeFirst()
        }
        return effects
    }

    // MARK: 暫定譯文

    private mutating func startProvisionalIfDue(at now: TimeInterval) -> [Effect] {
        guard configuration.provisional, let segment = live.segment, live.inFlight == nil,
            live.words - live.requestedWords >= Double(configuration.provisionalWords),
            now - live.requestedAt >= configuration.provisionalInterval
        else { return [] }
        let request = nextRequest
        nextRequest += 1
        requests[request] = .provisional(segment: segment)
        live.inFlight = (request, now)
        live.requestedWords = live.words
        live.requestedAt = now
        let context = history.suffix(configuration.contextSegments).map(\.text)
        return [.start(request: request, makeRequest(text: live.text, context: context, isFinal: false, strict: false))]
    }

    /// 進行中的這一段結束了（確定，或重新開始）：取消還沒回來的暫定譯文。
    private mutating func endProvisional() -> [Effect] {
        var effects: [Effect] = []
        if let inFlight = live.inFlight {
            effects.append(.cancel(request: inFlight.request))
            requests[inFlight.request] = nil
        }
        live = Live()
        return effects
    }

    // MARK: 請求的內容

    private func makeRequest(text: String, context: [String], isFinal: Bool, strict: Bool) -> TextRequest {
        var parts: [String] = []
        if !context.isEmpty {
            parts.append("前文（只供參考，不要翻譯）：\n" + context.joined(separator: "\n"))
        }
        parts.append((isFinal ? "這一段：\n" : "目前聽到的部分：\n") + text)
        return TextRequest(
            model: configuration.model,
            instructions: instructions(isFinal: isFinal, strict: strict),
            input: parts.joined(separator: "\n\n"),
            maxOutputTokens: 400,
            reasoningEffort: "none")
    }

    private func instructions(isFinal: Bool, strict: Bool) -> String {
        var lines: [String] = []
        if isFinal {
            lines.append("你是演講、課程與會議的即時字幕譯者。把使用者給的「這一段」英文翻成台灣繁體中文，供現場觀眾閱讀。")
        } else {
            lines.append("你是演講、課程與會議的即時字幕譯者。講者還沒說完，使用者給的是「目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。")
        }
        lines.append("規則：")
        lines.append("1. 使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。")
        lines.append("2. 產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。")
        lines.append("3. 數字用阿拉伯數字。語氣自然、精簡，像字幕。")
        if isFinal {
            lines.append("4. 這一段可能只是半句話：照聽到的內容翻譯，不要自行補完，也不要重複前文。")
            lines.append("5. 只輸出這一段的譯文，不要加任何說明。")
        } else {
            lines.append("4. 只翻譯已經聽到的內容，不要猜測或補完後面還沒說的部分，結尾不要加句號。")
            lines.append("5. 只輸出譯文，不要重複前文，不要加任何說明。")
        }
        if strict {
            lines.append("6. 只能使用繁體字，不可以出現任何簡體字。")
        }
        var info: [String] = []
        if !configuration.title.isEmpty { info.append("標題：\(configuration.title)") }
        if !configuration.event.isEmpty { info.append("活動：\(configuration.event)") }
        if !configuration.speaker.isEmpty { info.append("講者：\(configuration.speaker)") }
        if !info.isEmpty { lines.append("場次資訊（供參考）：" + info.joined(separator: "；")) }
        let keywords = TranscriptionCommand.cleaned(configuration.keywords)
        if !keywords.isEmpty {
            // 提示不宜無限長：最多帶 200 個
            lines.append("以下名稱出現時保留英文原文：" + keywords.prefix(200).joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    /// 去掉頭尾的空白與換行。
    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 字數：以空白分開、含有字母或數字的算一個字；中文字每 2 個算一個字（和 `Segmenter` 相同的算法）。
enum Words {
    static func count(_ text: String) -> Double {
        var total = 0.0
        for token in text.split(whereSeparator: \.isWhitespace) {
            var ideographs = 0
            var hasOther = false
            for character in token {
                if character.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
                    ideographs += 1
                } else if character.isLetter || character.isNumber {
                    hasOther = true
                }
            }
            total += Double(ideographs) / 2 + (hasOther ? 1 : 0)
        }
        return total
    }
}
