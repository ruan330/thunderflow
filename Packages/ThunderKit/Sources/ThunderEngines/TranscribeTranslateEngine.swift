import Foundation
import ThunderCore

/// v1 的即時字幕引擎：轉錄連線（英文）加上文字模型（台灣繁體中文）。DESIGN.md 5.6.2 節。
///
/// 四個部分都是不碰網路的純邏輯，各自有測試：
/// `PauseDetector`（停頓偵測）、`TranscriptionLink`（連線管理）、`Segmenter`（切段）、`TranslationPlanner`（翻譯排程）。
/// 這個型別是外殼：把音訊、伺服器的事件、文字模型的輸出與計時合併成一條依序處理的輸入，
/// 交給那四個部分做決定，再執行它們要求的動作（開連線、送訊息、送請求、送出字幕事件）。外殼本身不做判斷。
///
/// 事件的時間（`CaptionText.at`）是「到目前為止從等待區取走的音訊」的結尾，所以只增不減，也不會超過錄音的長度。
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

    private let configuration: Configuration
    private let apiKey: String
    private let connector: any RealtimeConnector
    private let textModel: any TextModel

    /// - Parameters:
    ///   - apiKey: 只放在記憶體裡，隨連線的 `Authorization` 標頭送出。
    ///   - connector: 建立轉錄連線的方式；測試時換成假連線。
    ///   - textModel: 翻譯用的文字模型；測試時換成假的。
    public init(
        configuration: Configuration = Configuration(),
        apiKey: String,
        connector: any RealtimeConnector = URLSessionRealtimeConnector(),
        textModel: any TextModel
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.connector = connector
        self.textModel = textModel
    }

    public func run(audio: AsyncStream<AudioChunk>, config: EngineConfig) -> AsyncStream<CaptionEvent> {
        let (events, output) = AsyncStream<CaptionEvent>.makeStream()
        let task = Task { [configuration, apiKey, connector, textModel] in
            let run = EngineRun(
                configuration: configuration, apiKey: apiKey, connector: connector, textModel: textModel, output: output)
            await run.run(audio: audio)
            output.finish()
        }
        // 沒有人讀事件了（場次放棄引擎）：盡快停止
        output.onTermination = { _ in task.cancel() }
        return events
    }
}

/// 引擎的一次執行。所有狀態只在 `run(audio:)` 的那一個 task 裡使用。
private final class EngineRun {
    enum Input: Sendable {
        case audio(AudioChunk)
        case audioEnded
        case message(connection: Int, String)
        case closed(connection: Int, TranscriptionLink.CloseReason)
        case progress(request: Int, String)
        case completed(request: Int, String)
        case failed(request: Int, reason: String)
        case tick
    }

    /// 一條轉錄連線，以及替它收送訊息的兩個 task。
    struct Connection {
        var socket: any RealtimeSocket
        var outbox: AsyncStream<String>.Continuation
        var sender: Task<Void, Never>
        var receiver: Task<Void, Never>
        var counter: OutboxCounter
    }

    private let configuration: TranscribeTranslateEngine.Configuration
    private let apiKey: String
    private let connector: any RealtimeConnector
    private let textModel: any TextModel
    private let output: AsyncStream<CaptionEvent>.Continuation

    private let inputs: AsyncStream<Input>
    private let feed: AsyncStream<Input>.Continuation
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    private var detector: PauseDetector
    private var link: TranscriptionLink
    private var segmenter: Segmenter
    private var planner: TranslationPlanner

    private var connections: [Int: Connection] = [:]
    private var requests: [Int: Task<Void, Never>] = [:]
    private var timer: (deadline: TimeInterval, task: Task<Void, Never>)?
    /// 到目前為止取走的音訊的結尾：事件的時間。
    private var audioEnd = AudioTime.zero
    private var linkFinished = false
    private var linkFailed = false
    /// 轉錄連線最近一次的狀態（翻譯失敗或恢復時，只有連線是即時的才改狀態列）。
    private var linkStatus: EngineStatus?
    /// 文字模型連續失敗的次數，以及翻譯目前失敗的原因（nil：正常）。
    private var consecutiveTextFailures = 0
    private var translationProblem: String?
    private var flushed = false
    /// 進行中的那一段的段號（最近一筆增量文字所屬的段）。
    private var liveSegment: Int?

    init(
        configuration: TranscribeTranslateEngine.Configuration,
        apiKey: String,
        connector: any RealtimeConnector,
        textModel: any TextModel,
        output: AsyncStream<CaptionEvent>.Continuation
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.connector = connector
        self.textModel = textModel
        self.output = output
        (inputs, feed) = AsyncStream<Input>.makeStream()
        origin = clock.now
        detector = PauseDetector(configuration: configuration.pause)
        link = TranscriptionLink(configuration: configuration.link, seed: UInt64.random(in: 1...UInt64.max))
        segmenter = Segmenter(configuration: configuration.segmenter)
        planner = TranslationPlanner(configuration: configuration.translation)
    }

    func run(audio: AsyncStream<AudioChunk>) async {
        let feed = feed
        let audioTask = Task {
            for await chunk in audio { feed.yield(.audio(chunk)) }
            feed.yield(.audioEnded)
        }
        defer {
            audioTask.cancel()
            timer?.task.cancel()
            for task in requests.values { task.cancel() }
            for number in Array(connections.keys) { closeConnection(number) }
            feed.finish()
        }

        apply(link.start(at: now()))
        scheduleTimer()

        for await input in inputs {
            let time = now()
            switch input {
            case .audio(let chunk):
                audioEnd = max(audioEnd, chunk.endTime)
                for event in detector.process(chunk) {
                    guard case .paused(let speechEnd, let detectedAt) = event else { continue }
                    // 停頓的時間是音訊時間；這一包的結尾就是「現在」，換算到和文字相同的時間軸
                    let stoppedAt = time - (chunk.endTime - speechEnd)
                    handle(segmenter.pauseDetected(speechEnd: stoppedAt, at: time - (chunk.endTime - detectedAt)), at: time)
                    apply(link.pauseDetected(at: time))
                }
                apply(link.audio(chunk, at: time))
            case .audioEnded:
                apply(link.audioEnded(at: time))
            case .message(let connection, let message):
                if let event = TranscriptionEvent(message: message) {
                    apply(link.received(event, connection: connection, at: time))
                }
            case .closed(let connection, let reason):
                closeConnection(connection)
                apply(link.closed(connection: connection, reason: reason, at: time))
            case .progress(let request, let text):
                apply(planner.progress(request: request, text: text, at: time))
            case .completed(let request, let text):
                requests[request] = nil
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { textSucceeded() }
                apply(planner.completed(request: request, text: text, at: time))
            case .failed(let request, let reason):
                requests[request] = nil
                textFailed(reason)
                apply(planner.failed(request: request, at: time))
            case .tick:
                break
            }

            // 到期的計時
            apply(link.advance(to: time))
            handle(segmenter.advance(to: time), at: time)
            apply(planner.advance(to: time))

            if linkFailed { break }
            if linkFinished {
                // 轉錄收尾了：把手上的文字定稿，等還在翻的段有結果就結束
                if !flushed {
                    flushed = true
                    handle(segmenter.flush(at: time), at: time)
                    // 整句模式：正在說的那一句當成說完了
                    apply(planner.flush(at: time))
                }
                if !planner.hasPendingFinals { break }
            }
            scheduleTimer()
        }
    }

    // MARK: 執行各部分要求的動作

    private func apply(_ effects: [TranscriptionLink.Effect]) {
        for effect in effects {
            switch effect {
            case .open(let number):
                openConnection(number)
            case .send(let number, let message):
                guard let connection = connections[number] else { continue }
                if connection.counter.increment() > configuration.stalledOutboxLimit {
                    // 送不出去的訊息越積越多：連線卡住了，當成斷線
                    feed.yield(.closed(connection: number, .lost))
                } else {
                    connection.outbox.yield(message)
                }
            case .close(let number):
                closeConnection(number)
            case .text(let text):
                handle(segmenter.receive(text, at: now()), at: now())
            case .status(let status):
                linkStatus = status
                // 連線恢復時，翻譯如果還在失敗，狀態列要繼續顯示翻譯失敗
                if status == .live, let problem = translationProblem {
                    output.yield(.status(.translationFailing(reason: problem)))
                } else {
                    output.yield(.status(status))
                }
                if case .failed = status { linkFailed = true }
            case .gap(let gap):
                output.yield(.gap(gap))
            case .billed(let seconds):
                output.yield(.usage(audioSeconds: seconds))
            case .finished:
                linkFinished = true
            }
        }
    }

    private func handle(_ outputs: [Segmenter.Output], at time: TimeInterval) {
        var grew = false
        for item in outputs {
            switch item {
            case .delta(let segment, let text):
                liveSegment = segment
                grew = true
                output.yield(.source(CaptionText(text: text, kind: .delta, at: audioEnd, segment: segment, sentence: openSentence)))
            case .finished(let segment, let text, let reason):
                // 句子的編號在交給翻譯排程之前就決定：這一段屬於正在說的那一句（它可能就在這一段結束）
                output.yield(
                    .source(CaptionText(text: text, kind: .segmentEnd, at: audioEnd, segment: segment, sentence: openSentence)))
                apply(planner.segmentFinished(segment, text: text, reason: reason, at: time))
            case .amended(let segment, let text):
                // 補上晚到的標點：英文更新，段的中文不用重翻；整句模式時，補上的句號讓這一句在這一段結束
                output.yield(
                    .source(
                        CaptionText(
                            text: text, kind: .segmentEnd, at: audioEnd, segment: segment, sentence: planner.sentence(of: segment))))
                if sentences { apply(planner.segmentAmended(segment, text: text, at: time)) }
            case .extended(let segment, let text):
                output.yield(
                    .source(
                        CaptionText(
                            text: text, kind: .segmentEnd, at: audioEnd, segment: segment, sentence: planner.sentence(of: segment))))
                apply(planner.segmentExtended(segment, text: text, at: time))
            }
        }
        if grew, let liveSegment {
            let pending = segmenter.pendingText
            if !pending.isEmpty { apply(planner.pendingText(pending, segment: liveSegment, at: time)) }
        }
    }

    /// 整句模式：英文帶的句子編號（正在說的那一句）。不是整句模式時是 nil。
    private var openSentence: Int? { sentences ? planner.openSentence : nil }
    private var sentences: Bool { planner.configuration.sentences }

    private func apply(_ effects: [TranslationPlanner.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let request, let content):
                startRequest(request, content)
            case .cancel(let request):
                requests.removeValue(forKey: request)?.cancel()
            case .translation(let segment, let text):
                output.yield(.translation(CaptionText(text: text, kind: .segmentEnd, at: audioEnd, segment: segment)))
            case .provisional(let segment, let text):
                output.yield(.provisional(CaptionText(text: text, kind: .delta, at: audioEnd, segment: segment)))
            case .sentenceProvisional(let number, let first, let text):
                // 整句的暫定譯文：帶句子的編號與這一句的第一段，字幕區把它當成這一句的灰字
                output.yield(
                    .provisional(
                        CaptionText(
                            text: text, kind: .delta, at: audioEnd, segment: liveSegment ?? first, sentence: number,
                            sentenceStart: first)))
            case .sentence(let number, let first, let last, let text):
                output.yield(
                    .translation(
                        CaptionText(
                            text: text, kind: .segmentEnd, at: audioEnd, segment: last, sentence: number, sentenceStart: first)))
            }
        }
    }

    // MARK: 連線與請求

    private func openConnection(_ number: Int) {
        let socket = connector.connect(to: configuration.endpoint, headers: ["Authorization": "Bearer \(apiKey)"])
        let (messages, outbox) = AsyncStream<String>.makeStream()
        let counter = OutboxCounter()
        let feed = feed
        let sender = Task {
            for await message in messages {
                do {
                    try await socket.send(message)
                    counter.decrement()
                } catch {
                    if !Task.isCancelled { feed.yield(.closed(connection: number, .lost)) }
                    return
                }
            }
        }
        let receiver = Task {
            while !Task.isCancelled {
                do {
                    feed.yield(.message(connection: number, try await socket.receive()))
                } catch {
                    let reason = (error as? RealtimeSocketClosed)?.reason ?? .lost
                    if !Task.isCancelled { feed.yield(.closed(connection: number, reason)) }
                    return
                }
            }
        }
        connections[number] = Connection(socket: socket, outbox: outbox, sender: sender, receiver: receiver, counter: counter)
    }

    private func closeConnection(_ number: Int) {
        guard let connection = connections.removeValue(forKey: number) else { return }
        // 先取消收送的 task，它們就不會把我們自己關掉的連線回報成斷線
        connection.receiver.cancel()
        connection.sender.cancel()
        connection.outbox.finish()
        connection.socket.close()
    }

    // MARK: 翻譯連續失敗

    /// 文字模型連續失敗幾次就回報 `translationFailing`。偶爾一兩次交給備援與重試，不改變狀態。
    private static let failureThreshold = 5

    private func textFailed(_ reason: String) {
        consecutiveTextFailures += 1
        guard consecutiveTextFailures >= Self.failureThreshold, translationProblem == nil else { return }
        translationProblem = reason
        if linkStatus == .live { output.yield(.status(.translationFailing(reason: reason))) }
    }

    private func textSucceeded() {
        consecutiveTextFailures = 0
        guard translationProblem != nil else { return }
        translationProblem = nil
        if linkStatus == .live { output.yield(.status(.live)) }
    }

    /// 錯誤的說明（給狀態列看）。文字模型的錯誤不含憑證；其他錯誤用系統的說明。
    private static func describe(_ error: any Error) -> String {
        if let error = error as? TextModelError { return error.description }
        return error.localizedDescription
    }

    private func startRequest(_ request: Int, _ content: TextRequest) {
        let feed = feed
        let textModel = textModel
        requests[request] = Task {
            var total = ""
            do {
                for try await piece in textModel.stream(content) {
                    total += piece
                    feed.yield(.progress(request: request, total))
                }
                if !Task.isCancelled { feed.yield(.completed(request: request, total)) }
            } catch {
                if !Task.isCancelled { feed.yield(.failed(request: request, reason: Self.describe(error))) }
            }
        }
    }

    // MARK: 時間

    private func now() -> TimeInterval {
        let elapsed = clock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }

    /// 在最近的期限叫醒自己。期限提前了才重排；延後的話讓原本的計時照常響一次（多醒一次無妨）。
    private func scheduleTimer() {
        let deadlines = [link.nextDeadline, segmenter.nextDeadline, planner.nextDeadline].compactMap { $0 }
        guard let deadline = deadlines.min() else { return }
        let time = now()
        if let timer, timer.deadline <= deadline + 0.001, timer.deadline > time { return }
        timer?.task.cancel()
        let delay = max(0, deadline - time)
        let feed = feed
        let task = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { feed.yield(.tick) }
        }
        timer = (deadline, task)
    }
}

/// 一條連線上還沒送出的訊息數。送出的一方（引擎的主迴圈）加，實際送完的 task 減。
private final class OutboxCounter: @unchecked Sendable {
    // @unchecked Sendable：唯一的狀態由鎖保護。
    private var count = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func decrement() {
        lock.lock()
        count -= 1
        lock.unlock()
    }
}
