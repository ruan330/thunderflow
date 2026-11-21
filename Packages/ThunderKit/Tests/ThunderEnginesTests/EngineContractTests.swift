import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 受測的引擎，以及「它已經消化了多少音訊」（用來一秒一秒地餵，不看時鐘）。
private struct EngineUnderTest {
    var engine: any LiveCaptionEngine
    var consumed: @Sendable () -> TimeInterval
    var connector: ReplayConnector?
    var model: ScriptedTextModel?
}

private enum EngineKind: String, CaseIterable, CustomStringConvertible, Sendable {
    case scripted = "腳本引擎"
    case transcribeTranslate = "轉錄＋翻譯引擎（假連線、假文字模型）"

    var description: String { rawValue }
}

private let fakeKey = "sk-test-FAKEKEY-0123456789abcdef"

private func makeEngine(
    _ kind: EngineKind,
    fixture: String = "keynote-single-turn",
    faults: [Int: ReplayConnector.Fault] = [:],
    reply: @escaping @Sendable (TextRequest, Int) -> ScriptedTextModel.Reply = { _, index in .text("中文 \(index)") },
    configure: (inout TranscribeTranslateEngine.Configuration) -> Void = { _ in }
) throws -> EngineUnderTest {
    switch kind {
    case .scripted:
        let engine = ScriptedEngine(.segments(every: 2))
        return EngineUnderTest(engine: engine, consumed: { engine.receivedDuration })
    case .transcribeTranslate:
        let connector = ReplayConnector(fixture: try RealtimeFixture.load(fixture), faults: faults)
        let model = ScriptedTextModel(reply: reply)
        var configuration = TranscribeTranslateEngine.Configuration()
        configuration.link.backoffBase = 0.01
        configuration.link.jitter = 0
        configure(&configuration)
        let engine = TranscribeTranslateEngine(configuration: configuration, apiKey: fakeKey, connector: connector, textModel: model)
        return EngineUnderTest(
            engine: engine, consumed: { connector.receivedAudioSeconds }, connector: connector, model: model)
    }
}

/// 收集事件的地方：引擎在另一個 task 上送，測試在這裡看。
private final class EventLog: Sendable {
    private let storage = LockedValue<[CaptionEvent]>([])
    private let ended = LockedValue(false)

    var events: [CaptionEvent] { storage.value }
    var hasEnded: Bool { ended.value }

    func append(_ event: CaptionEvent) { storage.withValue { $0.append(event) } }
    func end() { ended.withValue { $0 = true } }

    var isLive: Bool { events.contains(.status(.live)) }
    var statuses: [EngineStatus] {
        events.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }
}

struct FeedTimeout: Error, CustomStringConvertible {
    var description: String { "引擎沒有在時限內跟上送入的音訊，或沒有在時限內結束" }
}

/// 啟動引擎、等它連上、一秒一秒地餵 `seconds` 秒的音訊（每秒等它跟上），然後結束音訊並等事件串流結束。
private func play(
    _ subject: EngineUnderTest,
    seconds: Int,
    waitForLive: Bool = true,
    lockstep: Bool = true,
    allowedLag: TimeInterval = 0.5
) async throws -> [CaptionEvent] {
    let (audio, input) = AsyncStream<AudioChunk>.makeStream()
    let log = EventLog()
    let events = subject.engine.run(audio: audio, config: EngineConfig())
    let reader = Task {
        for await event in events { log.append(event) }
        log.end()
    }
    defer { reader.cancel() }

    if waitForLive {
        guard await waitUntil(timeout: .seconds(5), { log.isLive || log.hasEnded }) else { throw FeedTimeout() }
    }
    let chunk = Signal.audioChunks(Signal.silence(count: 4_800)).first!
    for second in 0..<seconds {
        for part in 0..<5 {
            var next = chunk
            next.startTime = AudioTime(seconds: Double(second) + Double(part) * 0.2)
            input.yield(next)
        }
        if lockstep, !log.hasEnded {
            let target = Double(second + 1) - allowedLag
            guard await waitUntil(timeout: .seconds(5), { subject.consumed() >= target || log.hasEnded }) else {
                throw FeedTimeout()
            }
        }
    }
    input.finish()
    guard await waitUntil(timeout: .seconds(10), { log.hasEnded }) else { throw FeedTimeout() }
    return log.events
}

private extension Array where Element == CaptionEvent {
    var sources: [CaptionText] { compactMap { if case .source(let text) = $0 { text } else { nil } } }
    var translations: [CaptionText] { compactMap { if case .translation(let text) = $0 { text } else { nil } } }
    var provisionals: [CaptionText] { compactMap { if case .provisional(let text) = $0 { text } else { nil } } }
    var statuses: [EngineStatus] { compactMap { if case .status(let status) = $0 { status } else { nil } } }

    /// 每一段最後確定的英文，依段號。
    var finalSources: [Int: String] {
        var result: [Int: String] = [:]
        for text in sources where text.kind == .segmentEnd {
            if let segment = text.segment { result[segment] = text.text }
        }
        return result
    }
}

private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("引擎契約：每一個引擎都要通過")
struct EngineContractTests {
    private static let keynoteSeconds = 94

    @Test("音訊結束會收尾：事件串流自己結束", arguments: EngineKind.allCases)
    fileprivate func finishesWhenAudioEnds(kind: EngineKind) async throws {
        let subject = try makeEngine(kind)
        let events = try await play(subject, seconds: Self.keynoteSeconds)
        #expect(!events.sources.isEmpty)
        #expect(!events.translations.isEmpty)
        if let connector = subject.connector {
            #expect(connector.commitCount == 1, "只在結束時 commit 一次")
            #expect(connector.records.allSatisfy { $0.closedByClient }, "結束時要關閉連線")
        }
    }

    @Test("事件串流被取消：盡快停止，連線也關掉", arguments: EngineKind.allCases)
    fileprivate func stopsWhenCancelled(kind: EngineKind) async throws {
        let subject = try makeEngine(kind)
        let (audio, input) = AsyncStream<AudioChunk>.makeStream()
        let log = EventLog()
        let events = subject.engine.run(audio: audio, config: EngineConfig())
        let reader = Task {
            for await event in events { log.append(event) }
            log.end()
        }
        let live = await waitUntil(timeout: .seconds(5), { log.isLive })
        #expect(live)
        input.yield(Signal.audioChunks(Signal.silence(count: 4_800)).first!)

        reader.cancel()  // 沒有人讀事件了；音訊沒有結束
        let ended = await waitUntil(timeout: .seconds(2), { log.hasEnded })
        #expect(ended)
        if let connector = subject.connector {
            let closed = await waitUntil(timeout: .seconds(2), { connector.records.allSatisfy(\.closedByClient) })
            #expect(closed)
        }
        _ = input
    }

    @Test("事件的時間只增不減，而且不超過送進去的音訊長度", arguments: EngineKind.allCases)
    fileprivate func timesAreMonotonic(kind: EngineKind) async throws {
        let events = try await play(try makeEngine(kind), seconds: Self.keynoteSeconds)
        var latest = AudioTime.zero
        for event in events {
            let at: AudioTime? =
                switch event {
                case .source(let text), .translation(let text), .provisional(let text): text.at
                default: nil
                }
            guard let at else { continue }
            #expect(at >= latest)
            #expect(at.seconds <= Double(Self.keynoteSeconds) + 1e-6)
            latest = max(latest, at)
        }
    }

    @Test("不變條件 8：段號從 0 開始一次加 1；補上的內容只接在最近確定的那一段；中文定稿對得上一段英文", arguments: EngineKind.allCases)
    fileprivate func segmentInvariant(kind: EngineKind) async throws {
        let events = try await play(try makeEngine(kind), seconds: Self.keynoteSeconds)
        var finished: [Int] = []  // 依確定的順序
        var known: Set<Int> = []
        for event in events {
            switch event {
            case .source(let text):
                let segment = try #require(text.segment)
                if text.kind == .segmentEnd {
                    if known.insert(segment).inserted {
                        #expect(segment == finished.count, "新確定的段，段號要接著編")
                        finished.append(segment)
                    } else {
                        #expect(segment == finished.last, "補上的標點與尾巴只能接在最近確定的那一段")
                    }
                } else {
                    #expect(segment == finished.count, "增量文字屬於下一個還沒確定的段")
                }
            case .translation(let text):
                let segment = try #require(text.segment)
                #expect(known.contains(segment), "定稿的段號要對得上一段已經確定的英文")
                #expect(text.kind == .segmentEnd)
            case .provisional(let text):
                #expect(text.segment != nil)
            default:
                break
            }
        }
        #expect(finished.count > 5)
    }
}

@Suite("轉錄＋翻譯引擎：接上假連線與假文字模型")
struct TranscribeTranslateEngineTests {
    @Test("重播 keynote：英文一字不漏，每個字恰好屬於一段；每一段都有中文定稿，而且依段的順序")
    func replaysKeynote() async throws {
        let subject = try makeEngine(.transcribeTranslate)
        let events = try await play(subject, seconds: 94)
        let transcript = try TranscriptFixture.load(events: "keynote-single-turn")

        let segments = events.finalSources
        let joined = segments.keys.sorted().compactMap { segments[$0] }.joined(separator: " ")
        #expect(normalized(joined) == normalized(transcript.text))
        #expect(segments.count >= 19, "19 句至少切成 19 段")

        let translated = events.translations.compactMap(\.segment)
        #expect(Set(translated) == Set(segments.keys), "每一段都有中文定稿")
        #expect(translated == translated.sorted(), "定稿依段的順序送出")
        #expect(events.contains(.status(.live)))
        #expect(!events.statuses.contains(.reconnecting))

        // 送出去的東西：設定在音訊之前，連線只到設定的主機，Key 只在標頭裡
        let connector = try #require(subject.connector)
        let record = try #require(connector.records.first)
        #expect(connector.records.count == 1)
        #expect(record.url.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
        #expect(record.headers == ["Authorization": "Bearer \(fakeKey)"])
        #expect(record.sent.first?.contains("session.update") == true)
        #expect(!record.sent.contains { $0.contains("FAKEKEY") })
        #expect(abs(connector.receivedAudioSeconds - 94) < 0.01)

        // 翻譯請求帶的是英文原文
        let model = try #require(subject.model)
        #expect(model.requests.contains { $0.input.contains("AgentCore") })
        if case .usage(let seconds)? = events.last(where: { if case .usage = $0 { true } else { false } }) {
            #expect(abs(seconds - 94) < 0.01)
        } else {
            Issue.record("應該回報計費秒數")
        }
    }

    @Test("文字模型全部失敗：英文照常送出，沒有中文定稿，也照常結束")
    func textModelDown() async throws {
        let subject = try makeEngine(.transcribeTranslate, reply: { _, _ in .failure(.http(status: 500, message: "down")) })
        let events = try await play(subject, seconds: 94)
        #expect(events.finalSources.count >= 19)
        #expect(events.translations.isEmpty)
        #expect(events.provisionals.isEmpty)
    }

    @Test("關閉暫定譯文：只送定稿的請求")
    func provisionalDisabled() async throws {
        let subject = try makeEngine(.transcribeTranslate, configure: { $0.translation.provisional = false })
        let events = try await play(subject, seconds: 94)
        #expect(events.provisionals.isEmpty)
        let model = try #require(subject.model)
        #expect(model.requests.count == events.finalSources.count)
        #expect(model.requests.allSatisfy { $0.input.contains("這一段") })
    }

    @Test("轉錄連線中途斷線：自動重新連線，字幕接著出來")
    func reconnects() async throws {
        let subject = try makeEngine(
            .transcribeTranslate, faults: [0: .closeAfter(audioMilliseconds: 20_000, reason: .lost)])
        // 斷線的那一瞬間正在送的幾包會遺失，所以引擎收到的音訊會比送進去的少一點
        let events = try await play(subject, seconds: 94, allowedLag: 5)
        let connector = try #require(subject.connector)

        try #require(connector.records.count == 2)
        #expect(connector.receivedAudioSeconds > 85, "收到 \(connector.receivedAudioSeconds) 秒")
        #expect(events.statuses.contains(.reconnecting))
        #expect(events.statuses.last == .live)
        #expect(events.finalSources.count >= 15)
        #expect(connector.records[1].sent.first?.contains("session.update") == true, "新的連線要重送設定")
        #expect(!events.statuses.contains { if case .failed = $0 { true } else { false } })
    }

    @Test("API Key 無效：回報失敗並結束，不重試")
    func invalidKey() async throws {
        let subject = try makeEngine(.transcribeTranslate, faults: [0: .refuse(.unauthorized)])
        let events = try await play(subject, seconds: 3, waitForLive: false, lockstep: false)
        let connector = try #require(subject.connector)

        guard case .failed(let reason)? = events.statuses.last else {
            Issue.record("最後的狀態應該是失敗：\(events.statuses)")
            return
        }
        #expect(reason.contains("API Key"))
        #expect(connector.records.count == 1)
        #expect(connector.receivedAudioSeconds == 0)
    }

    @Test("設定被拒絕（重播錄下的事件）：回報失敗，不送任何音訊")
    func rejectedSettings() async throws {
        let subject = try makeEngine(.transcribeTranslate, fixture: "rejected-delay")
        let events = try await play(subject, seconds: 3, waitForLive: false, lockstep: false)
        let connector = try #require(subject.connector)

        guard case .failed? = events.statuses.last else {
            Issue.record("最後的狀態應該是失敗：\(events.statuses)")
            return
        }
        #expect(connector.receivedAudioSeconds == 0)
        #expect(connector.records.count == 1)
    }

    @Test("來源夾雜中文（重播錄下的事件）：中文的句號也會切段，每一段都送去翻譯")
    func mixedLanguages() async throws {
        let subject = try makeEngine(.transcribeTranslate, fixture: "mixed-zh-en")
        let events = try await play(subject, seconds: 28)
        let transcript = try TranscriptFixture.load(events: "mixed-zh-en")
        let segments = events.finalSources
        // 中文之間沒有空白，所以比對時把空白都拿掉
        let joined = segments.keys.sorted().compactMap { segments[$0] }.joined()
        #expect(joined.filter { !$0.isWhitespace } == transcript.text.filter { !$0.isWhitespace })
        #expect(segments.count >= 5)
        #expect(events.translations.count == segments.count)
    }
}
