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
        /// 整句模式（DESIGN.md 5.6.2 節）：一句說完就把整句重新翻譯一次，取代這一句各段的定稿。
        public var sentences: Bool = false
        /// 整句的請求帶前幾句（英文與已經翻好的中文）當上下文。
        public var sentenceContext: Int = 3
        /// 一句累積到這麼多字還沒有句號，就在這一段結束時當成一句。
        public var sentenceWordLimit: Int = 60
        /// 一句的最後一段確定之後，這麼久都沒有新的字，就把這一句當成說完了。
        public var sentenceIdle: TimeInterval = 2.5
        /// 整句的暫定譯文（DESIGN.md 5.6.2 節）：整句模式、有暫定譯文時，暫定譯文翻的是「這一句目前聽到的部分」
        /// （已經確定的段＋進行中的文字），請求帶畫面上已經有的暫定譯文，請模型盡量保留、只在後面接上新的部分。
        /// 一句說完才結束；送出的時機照 `provisionalWords`、`provisionalInterval`。
        public var sentenceProvisional: Bool = false
        /// 整句的暫定譯文：每一句的第一個請求在這麼多字時就送，讓中文早一點出現；nil 時照 `provisionalWords`。
        /// 之後的請求照 `provisionalWords`、`provisionalInterval`（HANDOVER.md P11：第一個字 1.05 → 0.77 秒，改寫只多一點）。
        public var sentenceProvisionalFirstWords: Int?
        /// OpenAI 的處理等級（`priority`：每個請求快約 0.14 秒、單價較高；HANDOVER.md P11）。nil 表示預設，App 預設不用。
        public var serviceTier: String?
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
        /// 整句模式：第 `number` 句（第 `first` 段到第 `last` 段）的整句定稿，取代這幾段各自的定稿。
        case sentence(number: Int, first: Int, last: Int, text: String)
        /// 整句的暫定譯文：第 `number` 句（從第 `first` 段開始）目前聽到的部分的譯文（整句取代上一次的）。
        case sentenceProvisional(number: Int, first: Int, text: String)
    }

    private enum Outcome: Equatable {
        case translated(String)
        case failed
    }

    private enum Purpose: Equatable {
        case final(Job)
        case provisional(segment: Int)
        case draft(sentence: Int)
    }

    /// 一個定稿的工作：一段的定稿，或一整句的定稿（整句模式）。
    private enum Job: Equatable {
        case segment(Int)
        case sentence(Int)
    }

    /// 一段（或一整句）的定稿。
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
        /// 整句模式、一段的定稿：這一段是第幾句的最後一段。它自己的定稿只留著當整句失敗時的備用，不送出。
        var closes: Int?
        /// 整句模式、一整句的定稿：涵蓋哪幾段、帶什麼前文。
        var span: Span?
    }

    /// 一整句涵蓋的段與它的前文。
    private struct Span {
        var first: Int
        var last: Int
        var context: [Recent]
        /// 這一句的最後一段還在佇列裡：整句定稿依段的順序在那個位置送出。
        /// false（最後一段自己的定稿已經送出了）時，一有結果就直接送出。
        var viaQueue: Bool
    }

    /// 最近說完的一句：英文，以及翻好之後的中文。下一句的請求帶它當前文。
    private struct Recent {
        var number: Int
        var english: String
        var chinese: String?
    }

    /// 正在說的那一句。
    private struct OpenSentence {
        var number = 0
        var segments: [Int] = []
        var words = 0.0
        /// 最近一次有新的字（一段確定、補上標點，或進行中的那一段變長）的時間。
        var lastActivityAt: TimeInterval?
    }

    /// 整句的暫定譯文：正在說的那一句。
    private struct Draft {
        var number: Int
        /// 畫面上的暫定譯文（最近一次送出的）。
        var shown = ""
        /// 上一次請求送出時這一句的字數與時間。
        var requestedWords = 0.0
        var requestedAt = -Double.infinity
        var inFlight: (request: Int, startedAt: TimeInterval)?
        /// 最近一次請求送出的英文（檢查譯文裡的英文字是不是原文有的）。
        var english = ""
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

    // 整句模式
    /// 每一句的定稿，依句子的編號。送出之後還留一陣子：晚到的尾巴可能要重翻。
    private var sentenceFinals: [Int: Final] = [:]
    private var open = OpenSentence()
    /// 最近說完的幾句，給下一句當前文。
    private var recent: [Recent] = []
    /// 最近幾句的段：屬於第幾句、英文、自己的定稿（整句失敗時接起來當備用）。
    private var segmentSentence: [Int: Int] = [:]
    private var segmentEnglish: [Int: String] = [:]
    private var segmentChinese: [Int: String] = [:]
    /// 整句的暫定譯文（正在說的那一句）。
    private var draft: Draft?
    private var drafts: Bool { configuration.sentences && configuration.provisional && configuration.sentenceProvisional }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 是否還有定稿在等結果。收尾時要等它變成 false。
    public var hasPendingFinals: Bool {
        finals.values.contains { $0.outcome == nil } || sentenceFinals.values.contains { $0.outcome == nil }
    }

    /// 下一個需要呼叫 `advance(to:)` 的時間；沒有就是 nil。
    public var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        for final in Array(finals.values) + Array(sentenceFinals.values) where final.outcome == nil {
            deadlines.append(final.startedAt + configuration.giveUpAfter)
            if !final.hedged, !final.gotOutput { deadlines.append(final.startedAt + configuration.hedgeAfter) }
        }
        if let inFlight = live.inFlight { deadlines.append(inFlight.startedAt + configuration.provisionalTimeout) }
        if let inFlight = draft?.inFlight { deadlines.append(inFlight.startedAt + configuration.provisionalTimeout) }
        if configuration.sentences, !open.segments.isEmpty, let activity = open.lastActivityAt {
            deadlines.append(activity + configuration.sentenceIdle)
        }
        return deadlines.min()
    }

    // MARK: 輸入

    /// 整句模式：正在說的那一句的編號，下一段英文屬於這一句。
    public var openSentence: Int { open.number }

    /// 整句模式：第 `segment` 段屬於第幾句。不是整句模式，或是很久以前的段時是 nil。
    public func sentence(of segment: Int) -> Int? {
        configuration.sentences ? segmentSentence[segment] : nil
    }

    /// 第 `segment` 段的英文確定了。`reason` 是切段的原因：整句模式用它判斷一句是不是說完了。
    public mutating func segmentFinished(_ segment: Int, text: String, reason: Segmenter.Reason? = nil, at now: TimeInterval)
        -> [Effect]
    {
        var effects = advance(to: now)
        effects += endProvisional()
        // 已經送出、不會再變動的段可以丟掉了（晚到的尾巴只會併進最近確定的那一段）
        finals = finals.filter { !($0.value.emitted && $0.value.outcome != nil) }
        let context = history.suffix(configuration.contextSegments).map(\.text)
        history.append((segment, text))
        if history.count > configuration.contextSegments + 1 { history.removeFirst(history.count - configuration.contextSegments - 1) }
        finals[segment] = Final(english: text, context: context, startedAt: now)
        queue.append(segment)
        effects += startAttempt(for: .segment(segment))
        guard configuration.sentences else { return effects }

        segmentSentence[segment] = open.number
        segmentEnglish[segment] = text
        open.segments.append(segment)
        open.words += Words.count(text)
        open.lastActivityAt = now
        // 一句在這一段結束：句號；講者停太久或收尾；或一句已經太長
        let ends = reason == .sentenceEnd || reason == .idle || reason == .flush || TextFlow.endsSentence(text)
            || open.words >= Double(configuration.sentenceWordLimit)
        if ends { effects += closeSentence(at: now) }
        return effects
    }

    /// 第 `segment` 段（最近確定的那一段）補上了晚到的標點。段的定稿不用重翻；整句模式時，補上的如果是句號，這一句就在這一段結束。
    public mutating func segmentAmended(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard configuration.sentences else { return effects }
        if segmentEnglish[segment] != nil { segmentEnglish[segment] = text }
        if open.segments.last == segment {
            open.lastActivityAt = now
            if TextFlow.endsSentence(text) { effects += closeSentence(at: now) }
        }
        return effects
    }

    /// 收尾（音訊結束或暫停）：整句模式時，正在說的那一句當成說完了。
    public mutating func flush(at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        if configuration.sentences { effects += closeSentence(at: now) }
        effects += endDraft()
        return effects
    }

    /// 第 `segment` 段（最近確定的那一段）併入了晚到的尾巴，`text` 是併入之後整段的英文：重新翻譯。
    /// 整句模式時，晚到的尾巴是一句的結尾：這一句在這一段結束；這一句已經結束的，整句重翻（已經送出的翻完再送一次）。
    public mutating func segmentExtended(_ segment: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        // 尾巴原本算在下一段，那一段現在重新開始
        effects += endProvisional()
        if let index = history.lastIndex(where: { $0.segment == segment }) { history[index].text = text }
        if configuration.sentences, segmentEnglish[segment] != nil { segmentEnglish[segment] = text }
        if var final = finals[segment] {
            for request in final.inFlight.sorted() {
                effects.append(.cancel(request: request))
                requests[request] = nil
            }
            final = Final(english: text, context: final.context, startedAt: now, emitted: final.emitted, closes: final.closes)
            finals[segment] = final
            effects += startAttempt(for: .segment(segment))
        } else if configuration.sentences, segmentSentence[segment] != nil {
            // 這一段自己的定稿早就送出了：重翻的結果只留著當整句的備用
            finals[segment] = Final(english: text, context: [], startedAt: now, emitted: true)
            effects += startAttempt(for: .segment(segment))
        } else {
            return effects + segmentFinished(segment, text: text, at: now)
        }
        guard configuration.sentences else { return effects }
        if let number = coveringSentence(segment) {
            effects += retranslateSentence(number, at: now)
        } else if open.segments.last == segment {
            open.lastActivityAt = now
            effects += closeSentence(at: now)
        }
        return effects
    }

    /// 進行中的第 `segment` 段目前的英文（還沒確定）。每次文字變長就呼叫。
    public mutating func pendingText(_ text: String, segment: Int, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        if configuration.sentences { open.lastActivityAt = now }
        guard configuration.provisional else { return effects }
        if drafts {
            live.segment = segment
            live.text = text
            live.words = Words.count(text)
            return effects + startDraftIfDue(at: now)
        }
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
        case .final(let job):
            self[job]?.gotOutput = true
        case .provisional(let segment):
            // 這一段的第一個暫定譯文邊收邊送；之後的版本等完整回來才取代，免得畫面上的字先縮短再變長
            if segment == live.segment, !live.shown, output != live.emitted {
                live.emitted = output
                effects.append(.provisional(segment: segment, text: output))
            }
        case .draft(let number):
            // 收到的字接得上畫面上的字（以它開頭、而且更長）就先送出；接不上的等完整回來再整個換掉
            guard var current = draft, current.number == number, current.inFlight?.request == request,
                output.count > current.shown.count, output.hasPrefix(current.shown), acceptable(output, english: current.english),
                let first = draftFirstSegment
            else { break }
            current.shown = output
            draft = current
            effects.append(.sentenceProvisional(number: number, first: first, text: output))
        }
        return effects
    }

    /// 第 `request` 個請求完成了，`text` 是完整的輸出。
    public mutating func completed(request: Int, text: String, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard let purpose = requests.removeValue(forKey: request) else { return effects }
        let output = Self.cleaned(text)
        switch purpose {
        case .final(let job):
            guard var final = self[job], final.outcome == nil else { break }
            final.inFlight.remove(request)
            self[job] = final
            if output.isEmpty {
                effects += attemptEnded(for: job, at: now)
            } else if ChineseScript.containsSimplified(output), !final.strict {
                // 出現簡體字：重試一次，這一次明確要求只用繁體字
                for other in final.inFlight.sorted() {
                    effects.append(.cancel(request: other))
                    requests[other] = nil
                }
                final.inFlight = []
                final.strict = true
                final.fallback = output
                self[job] = final
                effects += startAttempt(for: job)
            } else {
                effects += resolve(job, .translated(output))
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
        case .draft(let number):
            guard var current = draft, current.number == number, current.inFlight?.request == request else { break }
            current.inFlight = nil
            if !output.isEmpty, output != current.shown, acceptable(output, english: current.english), let first = draftFirstSegment {
                current.shown = output
                effects.append(.sentenceProvisional(number: number, first: first, text: output))
            }
            draft = current
            effects += startDraftIfDue(at: now)
        }
        return effects
    }

    /// 第 `request` 個請求失敗了。
    public mutating func failed(request: Int, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard let purpose = requests.removeValue(forKey: request) else { return effects }
        switch purpose {
        case .final(let job):
            self[job]?.inFlight.remove(request)
            effects += attemptEnded(for: job, at: now)
        case .provisional:
            if live.inFlight?.request == request { live.inFlight = nil }
        case .draft:
            if draft?.inFlight?.request == request { draft?.inFlight = nil }
        }
        return effects
    }

    /// 時間前進到 `now`：處理到期的事（備援請求、放棄、講者停下來的那一句、暫定譯文逾時）。
    public mutating func advance(to now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        let jobs = finals.keys.sorted().map(Job.segment) + sentenceFinals.keys.sorted().map(Job.sentence)
        for job in jobs {
            guard let final = self[job], final.outcome == nil else { continue }
            if now >= final.startedAt + configuration.giveUpAfter {
                effects += resolve(job, final.fallback.map { .translated($0) } ?? .failed)
            } else if !final.hedged, !final.gotOutput, now >= final.startedAt + configuration.hedgeAfter {
                self[job]?.hedged = true
                if final.attempts < configuration.maximumAttempts { effects += startAttempt(for: job) }
            }
        }
        if configuration.sentences, !open.segments.isEmpty, let activity = open.lastActivityAt,
            now >= activity + configuration.sentenceIdle
        {
            // 講者停下來了：正在說的那一句當成說完了
            effects += closeSentence(at: now)
        }
        if let inFlight = live.inFlight, now >= inFlight.startedAt + configuration.provisionalTimeout {
            effects.append(.cancel(request: inFlight.request))
            requests[inFlight.request] = nil
            live.inFlight = nil
            effects += startProvisionalIfDue(at: now)
        }
        if let inFlight = draft?.inFlight, now >= inFlight.startedAt + configuration.provisionalTimeout {
            effects.append(.cancel(request: inFlight.request))
            requests[inFlight.request] = nil
            draft?.inFlight = nil
            effects += startDraftIfDue(at: now)
        }
        return effects
    }

    // MARK: 定稿

    private subscript(job: Job) -> Final? {
        get {
            switch job {
            case .segment(let segment): finals[segment]
            case .sentence(let number): sentenceFinals[number]
            }
        }
        set {
            switch job {
            case .segment(let segment): finals[segment] = newValue
            case .sentence(let number): sentenceFinals[number] = newValue
            }
        }
    }

    private mutating func startAttempt(for job: Job) -> [Effect] {
        guard var final = self[job] else { return [] }
        let request = nextRequest
        nextRequest += 1
        final.inFlight.insert(request)
        final.attempts += 1
        self[job] = final
        requests[request] = .final(job)
        let content =
            switch job {
            case .segment: makeRequest(text: final.english, context: final.context, isFinal: true, strict: final.strict)
            case .sentence: makeSentenceRequest(english: final.english, context: currentContext(final.span), strict: final.strict)
            }
        return [.start(request: request, content)]
    }

    /// 一個請求沒有結果（失敗或輸出是空的）：還有別的請求在跑就等它；否則在期限內重試，不然就放棄。
    private mutating func attemptEnded(for job: Job, at now: TimeInterval) -> [Effect] {
        guard let final = self[job], final.outcome == nil, final.inFlight.isEmpty else { return [] }
        if final.attempts < configuration.maximumAttempts, now < final.startedAt + configuration.giveUpAfter {
            return startAttempt(for: job)
        }
        return resolve(job, final.fallback.map { .translated($0) } ?? .failed)
    }

    private mutating func resolve(_ job: Job, _ outcome: Outcome) -> [Effect] {
        guard var final = self[job] else { return [] }
        var effects: [Effect] = []
        for request in final.inFlight.sorted() {
            effects.append(.cancel(request: request))
            requests[request] = nil
        }
        final.inFlight = []
        final.outcome = outcome
        let reissue = final.emitted
        self[job] = final
        switch job {
        case .segment(let segment):
            if configuration.sentences, case .translated(let text) = outcome { segmentChinese[segment] = text }
            if reissue {
                // 重新翻譯的結果：這一段已經輪過了，直接再送一次（被一整句涵蓋的段不送：整句定稿會重送）
                if case .translated(let text) = outcome, coveringSentence(segment) == nil {
                    effects.append(.translation(segment: segment, text: text))
                }
            } else {
                effects += flushQueue()
            }
        case .sentence(let number):
            if case .translated(let text) = outcome, let index = recent.lastIndex(where: { $0.number == number }) {
                recent[index].chinese = text
            }
            if reissue || final.span?.viaQueue == false {
                effects += emitSentence(number, replacing: reissue)
            } else {
                effects += flushQueue()
            }
        }
        return effects
    }

    /// 依順序送出已經有結果的定稿，遇到還在等的就停。
    ///
    /// 整句模式：一句已經有結果時，整句定稿取代這一句還在佇列裡的段；
    /// 還沒有結果時，這一句前面的段照常送出自己的定稿，最後一段等整句定稿。
    private mutating func flushQueue() -> [Effect] {
        var effects: [Effect] = []
        while let segment = queue.first, let final = finals[segment] {
            if let number = coveringSentence(segment), let sentence = sentenceFinals[number], let span = sentence.span,
                span.viaQueue, let outcome = sentence.outcome
            {
                // 整句失敗時要用各段自己的定稿接起來：等它們都有結果
                if outcome == .failed, queue.prefix(while: { $0 <= span.last }).contains(where: { finals[$0]?.outcome == nil }) {
                    break
                }
                effects += emitSentence(number, replacing: false)
                while let first = queue.first, first <= span.last {
                    finals[first]?.emitted = true
                    queue.removeFirst()
                }
                continue
            }
            // 一句的最後一段：等整句定稿
            if final.closes != nil { break }
            guard let outcome = final.outcome else { break }
            if case .translated(let text) = outcome { effects.append(.translation(segment: segment, text: text)) }
            finals[segment]?.emitted = true
            queue.removeFirst()
        }
        return effects
    }

    // MARK: 整句

    /// 正在說的那一句說完了：送出整句的請求，下一段開始新的一句。沒有正在說的句子時什麼都不做。
    private mutating func closeSentence(at now: TimeInterval) -> [Effect] {
        guard let first = open.segments.first, let last = open.segments.last else { return [] }
        let ended = endDraft()
        let number = open.number
        let english = open.segments.compactMap { segmentEnglish[$0] }.joined(separator: " ")
        let context = Array(recent.suffix(configuration.sentenceContext))
        recent.append(Recent(number: number, english: english))
        if recent.count > configuration.sentenceContext { recent.removeFirst(recent.count - configuration.sentenceContext) }
        // 最後一段自己的定稿還沒送出：只留著備用，整句定稿依段的順序在它的位置送出
        let viaQueue = finals[last].map { !$0.emitted } ?? false
        if viaQueue { finals[last]?.closes = number }
        sentenceFinals[number] = Final(
            english: english, context: [], startedAt: now,
            span: Span(first: first, last: last, context: context, viaQueue: viaQueue))
        open = OpenSentence(number: number + 1)
        forgetOldSentences()
        return ended + startAttempt(for: .sentence(number))
    }

    /// 已經結束的第 `number` 句又有變動（併入晚到的尾巴）：用新的英文重翻整句。已經送出的，翻完再送一次。
    private mutating func retranslateSentence(_ number: Int, at now: TimeInterval) -> [Effect] {
        guard let final = sentenceFinals[number], let span = final.span else { return [] }
        var effects: [Effect] = []
        for request in final.inFlight.sorted() {
            effects.append(.cancel(request: request))
            requests[request] = nil
        }
        let english = (span.first...span.last).compactMap { segmentEnglish[$0] }.joined(separator: " ")
        sentenceFinals[number] = Final(english: english, context: [], startedAt: now, emitted: final.emitted, span: span)
        return effects + startAttempt(for: .sentence(number))
    }

    /// 送出第 `number` 句的整句定稿。整句失敗時改用各段自己的定稿接起來；
    /// 重新翻譯（`replacing`）失敗時什麼都不送，畫面上原本的整句定稿比各段接起來的好。
    private mutating func emitSentence(_ number: Int, replacing: Bool) -> [Effect] {
        guard let final = sentenceFinals[number], let span = final.span, let outcome = final.outcome else { return [] }
        var effects: [Effect] = []
        switch outcome {
        case .translated(let text):
            effects += supersedeSegments(span)
            effects.append(.sentence(number: number, first: span.first, last: span.last, text: text))
        case .failed:
            let backup = TextFlow.join((span.first...span.last).compactMap { segmentChinese[$0] })
            if !replacing, !backup.isEmpty {
                effects.append(.sentence(number: number, first: span.first, last: span.last, text: backup))
            }
        }
        sentenceFinals[number]?.emitted = true
        return effects
    }

    /// 整句定稿到了：這一句各段還沒回來的請求不用再等。
    private mutating func supersedeSegments(_ span: Span) -> [Effect] {
        var effects: [Effect] = []
        for segment in span.first...span.last {
            guard var final = finals[segment] else { continue }
            for request in final.inFlight.sorted() {
                effects.append(.cancel(request: request))
                requests[request] = nil
            }
            final.inFlight = []
            if final.outcome == nil { final.outcome = .failed }
            final.emitted = true
            finals[segment] = final
        }
        return effects
    }

    /// 第 `segment` 段屬於一句已經結束的句子時，那一句的編號。
    private func coveringSentence(_ segment: Int) -> Int? {
        guard configuration.sentences, let number = segmentSentence[segment], number < open.number,
            sentenceFinals[number] != nil
        else { return nil }
        return number
    }

    /// 整句的請求帶的前文：說完的時候記下的那幾句，中文用目前已經翻好的。
    private func currentContext(_ span: Span?) -> [Recent] {
        (span?.context ?? []).map { item in
            var item = item
            if let latest = recent.last(where: { $0.number == item.number })?.chinese { item.chinese = latest }
            return item
        }
    }

    /// 很久以前、已經送出的句子不會再變動：只留最近幾句的紀錄（晚到的尾巴只會併進最近的一段）。
    private mutating func forgetOldSentences() {
        let keep = open.number - 3
        for (number, final) in sentenceFinals where number < keep && final.emitted && final.outcome != nil {
            sentenceFinals[number] = nil
        }
        let oldest = sentenceFinals.keys.min() ?? open.number
        for (segment, number) in segmentSentence where number < oldest {
            segmentSentence[segment] = nil
            segmentEnglish[segment] = nil
            segmentChinese[segment] = nil
        }
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

    // MARK: 整句的暫定譯文

    /// 正在說的那一句的第一段：已經確定的段，或還沒有確定的段時是進行中的這一段。
    private var draftFirstSegment: Int? { open.segments.first ?? live.segment }

    /// 這一句每多 `provisionalWords` 個字、而且距離上一次至少 `provisionalInterval`，就把這一句目前聽到的部分送去翻譯。
    private mutating func startDraftIfDue(at now: TimeInterval) -> [Effect] {
        guard drafts, draftFirstSegment != nil else { return [] }
        if draft?.number != open.number { draft = Draft(number: open.number) }
        guard var current = draft, current.inFlight == nil else { return [] }
        let words = open.words + live.words
        let due: Bool
        if current.requestedAt == -.infinity, let first = configuration.sentenceProvisionalFirstWords {
            due = words >= Double(first)
        } else {
            due = words - current.requestedWords >= Double(configuration.provisionalWords)
                && now - current.requestedAt >= configuration.provisionalInterval
        }
        guard due else { return [] }
        let english = TextFlow.join(open.segments.compactMap { segmentEnglish[$0] } + [live.text])
        let request = nextRequest
        nextRequest += 1
        requests[request] = .draft(sentence: current.number)
        current.inFlight = (request, now)
        current.requestedWords = words
        current.requestedAt = now
        current.english = english
        draft = current
        // 前文只帶已經翻好的句子：只有英文的那一句，模型常常會把它也翻進這一句（HANDOVER.md P11）
        let context = recent.suffix(configuration.sentenceContext).filter { $0.chinese != nil }
        return [.start(request: request, makeDraftRequest(english: english, context: Array(context), shown: current.shown))]
    }

    /// 暫定譯文可以顯示：沒有簡體字，也沒有原文沒有的英文字（3 個字母以上；模型偶爾會把雜訊輸出來）。
    /// 原文、場次資訊與關鍵詞裡有的名稱照常。
    private func acceptable(_ output: String, english: String) -> Bool {
        guard !ChineseScript.containsSimplified(output) else { return false }
        let known = ([english, configuration.title, configuration.event, configuration.speaker] + configuration.keywords)
            .joined(separator: " ").lowercased()
        var word = ""
        for character in output + " " {
            if character.isASCII, character.isLetter {
                word.append(character)
                continue
            }
            if word.count >= 3, !known.contains(word.lowercased()) { return false }
            word = ""
        }
        return true
    }

    /// 一句說完（或收尾）：取消還沒回來的整句暫定譯文。
    private mutating func endDraft() -> [Effect] {
        guard let current = draft else { return [] }
        draft = nil
        guard let inFlight = current.inFlight else { return [] }
        requests[inFlight.request] = nil
        return [.cancel(request: inFlight.request)]
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
            reasoningEffort: "none",
            serviceTier: configuration.serviceTier)
    }

    /// 整句的請求：前文是最近幾句的英文與已經翻好的中文，最後是這一句的英文。
    private func makeSentenceRequest(english: String, context: [Recent], strict: Bool) -> TextRequest {
        var parts: [String] = []
        if !context.isEmpty {
            let lines = context.map { item in item.chinese.map { "英：\(item.english)\n中：\($0)" } ?? "英：\(item.english)" }
            parts.append("前文（只供參考，不要翻譯）：\n" + lines.joined(separator: "\n"))
        }
        parts.append("這一句：\n" + english)
        return TextRequest(
            model: configuration.model,
            instructions: sentenceInstructions(strict: strict),
            input: parts.joined(separator: "\n\n"),
            maxOutputTokens: 400,
            reasoningEffort: "none",
            serviceTier: configuration.serviceTier)
    }

    /// 整句的暫定譯文的請求：前文（最近幾句的英文與中文）、畫面上的暫定譯文、這一句目前聽到的部分。
    private func makeDraftRequest(english: String, context: [Recent], shown: String) -> TextRequest {
        var parts: [String] = []
        if !context.isEmpty {
            let lines = context.map { item in item.chinese.map { "英：\(item.english)\n中：\($0)" } ?? "英：\(item.english)" }
            parts.append("前文（只供參考，不要翻譯）：\n" + lines.joined(separator: "\n"))
        }
        if !shown.isEmpty { parts.append("畫面上的暫定譯文：\n" + shown) }
        parts.append("這一句目前聽到的部分：\n" + english)
        return TextRequest(
            model: configuration.model,
            instructions: draftInstructions(),
            input: parts.joined(separator: "\n\n"),
            maxOutputTokens: 400,
            reasoningEffort: "none",
            serviceTier: configuration.serviceTier)
    }

    /// 整句的暫定譯文的提示（HANDOVER.md P11 的實驗：保留畫面上的字，翻錯或接不通順時才改）。
    private func draftInstructions() -> String {
        let lines = [
            "你是演講、課程與會議的即時字幕譯者。講者這一句還沒說完，使用者給的是「這一句目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。",
            "規則：",
            "1. 譯成通順、自然的中文：依中文的語序組織，但只翻已經聽到的內容，不要猜測或補完還沒說的部分。",
            "2. 這是現場的口語：去掉 uh、um、you know、I mean，以及當口頭禪用的 right、like、so，還有重複的字和說到一半改口的部分，只留下講者要表達的意思。",
            "3. 「前文」是剛才的英文和已經顯示給觀眾的中文：用語與稱呼要和前文的中文一致，但不要重複前文已經翻過的內容。",
            "4. " + Self.taiwanTerms,
            "5. " + Self.keepNames,
            "6. " + Self.subtitleStyle,
            "7. 結尾不要加句號。只輸出譯文，不要加任何說明。",
            "8. 「畫面上的暫定譯文」是觀眾正在看的這一句的譯文。請盡量一字不改地以它開頭，只在後面接上新聽到的部分；但如果它翻錯了，或照著它接下去會不通順，就修改它。",
        ]
        return (lines + sessionLines()).joined(separator: "\n")
    }

    /// 整句的提示：譯成通順的中文、去掉口語的贅字、和前文的中文接得上（HANDOVER.md P10 的實驗）。
    private func sentenceInstructions(strict: Bool) -> String {
        var lines = [
            "你是演講、課程與會議的即時字幕譯者。把使用者給的「這一句」英文翻成台灣繁體中文，供現場觀眾閱讀。",
            "規則：",
            "1. 譯成通順、自然的中文句子：依中文的語序重新組織，不要照英文的順序逐字翻。",
            "2. 這是現場的口語：去掉 uh、um、you know、I mean，以及當口頭禪用的 right、like、so，還有重複的字和說到一半改口的部分，只留下講者要表達的意思。",
            "3. 「前文」是剛才的英文和已經顯示給觀眾的中文：用語與稱呼要和前文的中文一致，接得上前文，但不要重複前文已經翻過的內容。",
            "4. " + Self.taiwanTerms,
            "5. " + Self.keepNames,
            "6. " + Self.subtitleStyle,
            "7. 只輸出這一句的譯文，不要加任何說明。",
        ]
        if strict { lines.append("8. 只能使用繁體字，不可以出現任何簡體字。") }
        return (lines + sessionLines()).joined(separator: "\n")
    }

    private static let taiwanTerms = "使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。"
    private static let keepNames =
        "產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。"
    private static let subtitleStyle = "數字用阿拉伯數字。語氣自然、精簡，像字幕。"

    /// 場次資訊與關鍵詞（段的請求與整句的請求都帶）。
    private func sessionLines() -> [String] {
        var lines: [String] = []
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
        return lines
    }

    private func instructions(isFinal: Bool, strict: Bool) -> String {
        var lines: [String] = []
        if isFinal {
            lines.append("你是演講、課程與會議的即時字幕譯者。把使用者給的「這一段」英文翻成台灣繁體中文，供現場觀眾閱讀。")
        } else {
            lines.append("你是演講、課程與會議的即時字幕譯者。講者還沒說完，使用者給的是「目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。")
        }
        lines.append("規則：")
        lines.append("1. " + Self.taiwanTerms)
        lines.append("2. " + Self.keepNames)
        lines.append("3. " + Self.subtitleStyle)
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
        return (lines + sessionLines()).joined(separator: "\n")
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
