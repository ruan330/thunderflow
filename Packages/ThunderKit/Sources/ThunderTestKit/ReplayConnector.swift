import Foundation
import ThunderCore
import ThunderEngines

/// 實驗時錄下來的轉錄連線事件（`Benchmarks/fixtures/openai-transcribe/*.jsonl`），原樣保留每一行。
///
/// `TranscriptFixture` 只取增量文字；這個型別保留伺服器事件的 JSON 原文與用戶端的動作，給連線管理的測試重播。
public struct RealtimeFixture: Sendable {
    public struct Line: Sendable, Equatable {
        /// 當時已經送出多少音訊（毫秒）。
        public var sentMilliseconds: Int
        /// 收到的時間（秒，從開始送音訊算起）；開始送音訊之前的事件是 nil。
        public var receivedAt: TimeInterval?
        /// 伺服器事件的 JSON 原文；這一行是用戶端的動作時是 nil。
        public var message: String?
        /// 用戶端的動作（例如 `commit`）；這一行是伺服器事件時是 nil。
        public var clientAction: String?
    }

    public var lines: [Line]

    /// 伺服器事件，依錄下來的順序。
    public var serverLines: [Line] { lines.filter { $0.message != nil } }

    public static func load(_ name: String, near sourceFile: String = #filePath) throws -> RealtimeFixture {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        var found: URL?
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(TranscriptFixture.relativeDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        guard let found else {
            throw TranscriptFixture.NotFound(path: TranscriptFixture.relativeDirectory, startedFrom: sourceFile)
        }
        var lines: [Line] = []
        for raw in try Data(contentsOf: found.appendingPathComponent("\(name).jsonl")).split(separator: UInt8(ascii: "\n")) {
            guard let record = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
            let sent = (record["sent_ms"] as? NSNumber)?.intValue ?? 0
            let received = (record["rx_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            if let event = record["event"] {
                let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
                lines.append(
                    Line(sentMilliseconds: sent, receivedAt: received, message: String(decoding: data, as: UTF8.self), clientAction: nil))
            } else if let action = record["client"] as? String {
                lines.append(Line(sentMilliseconds: sent, receivedAt: received, message: nil, clientAction: action))
            }
        }
        return RealtimeFixture(lines: lines)
    }
}

/// 重播錄下來的事件的假連線：不連網路，行為只取決於引擎送了什麼，不看時鐘。
///
/// - 連上就送出錄下來的 `session.created`。
/// - 收到設定（`session.update`）就回錄下來的下一個回應：`session.updated`，或設定被拒絕時的 `error`。
/// - 每收到一包音訊，就送出「錄的時候，音訊送到這個位置之前收到的事件」。所以引擎用任何速度送音訊，收到的內容都一樣。
/// - 收到 commit，就把直到下一個完成事件為止的事件都送出來。
///
/// 重新連線時從上次的位置接著播。也可以演出故障（`Fault`）。
public final class ReplayConnector: RealtimeConnector, @unchecked Sendable {
    public enum Fault: Sendable, Equatable {
        /// 這條連線收到這麼多毫秒的音訊後，以這個原因斷線。
        case closeAfter(audioMilliseconds: Int, reason: TranscriptionLink.CloseReason)
        /// 一連上就以這個原因斷線。
        case refuse(TranscriptionLink.CloseReason)
        /// 連得上，但伺服器什麼都不回。
        case silent
    }

    public struct Record: Sendable, Equatable {
        public var url: URL
        public var headers: [String: String]
        /// 引擎在這條連線上送出的訊息，依順序。
        public var sent: [String]
        public var closedByClient: Bool
    }

    fileprivate struct Shared {
        var cursor = 0
        var audioBytes = 0
        var records: [Record] = []
    }

    private let script: [RealtimeFixture.Line]
    private let faults: [Int: Fault]
    private let shared = LockedValue(Shared())

    /// - Parameters:
    ///   - fixture: 要重播的事件。
    ///   - faults: 第幾條連線（從 0 開始）要演出什麼故障。
    public init(fixture: RealtimeFixture, faults: [Int: Fault] = [:]) {
        script = fixture.serverLines
        self.faults = faults
    }

    /// 每一條連線的紀錄，依建立的順序。
    public var records: [Record] { shared.value.records }

    /// 所有連線合計收到的音訊長度（秒，以 24 kHz PCM16 計）。
    public var receivedAudioSeconds: Double { Double(shared.value.audioBytes) / 48_000 }

    /// 所有連線合計收到幾次 commit。
    public var commitCount: Int {
        shared.value.records.flatMap(\.sent).filter { $0.contains("input_audio_buffer.commit") }.count
    }

    public func connect(to url: URL, headers: [String: String]) -> any RealtimeSocket {
        let index = shared.withValue { state -> Int in
            state.records.append(Record(url: url, headers: headers, sent: [], closedByClient: false))
            return state.records.count - 1
        }
        return Socket(owner: self, index: index, fault: faults[index])
    }

    // MARK: 劇本

    fileprivate func created() -> String {
        script.first { $0.message?.contains("\"session.created\"") ?? false }?.message
            ?? #"{"type":"session.created","session":{"type":"transcription"}}"#
    }

    /// 設定之後的回應：劇本裡第一個 `session.updated` 或 `error`。
    fileprivate func configured() -> String {
        for line in script {
            guard let message = line.message else { continue }
            if message.contains("\"session.updated\"") || message.contains("\"type\":\"error\"") { return message }
        }
        return #"{"type":"session.updated","session":{"type":"transcription"}}"#
    }

    /// 音訊送到目前位置之前該收到的事件。`untilCompletion`：再往後送到下一個完成事件為止（commit 的回應）。
    fileprivate func due(untilCompletion: Bool) -> [String] {
        shared.withValue { state in
            let position = state.audioBytes / 48
            var messages: [String] = []
            while state.cursor < script.count {
                let line = script[state.cursor]
                guard let message = line.message else {
                    state.cursor += 1
                    continue
                }
                // 連線與設定階段的事件由 created()、configured() 負責
                if message.contains("\"session.created\"") || message.contains("\"session.updated\"") {
                    state.cursor += 1
                    continue
                }
                if line.sentMilliseconds <= position || untilCompletion {
                    messages.append(message)
                    state.cursor += 1
                    if untilCompletion, line.sentMilliseconds > position,
                        message.contains("input_audio_transcription.completed")
                    {
                        break
                    }
                } else {
                    break
                }
            }
            return messages
        }
    }

    fileprivate func record(_ message: String, index: Int) -> Int {
        shared.withValue { state in
            state.records[index].sent.append(message)
            if message.hasPrefix("{\"type\":\"input_audio_buffer.append\"") {
                // base64：每 4 個字元是 3 個位元組
                let payload = message.count - "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\"}".count
                state.audioBytes += payload / 4 * 3
            }
            return state.audioBytes
        }
    }

    fileprivate func markClosed(index: Int) {
        shared.withValue { $0.records[index].closedByClient = true }
    }

    // MARK: 連線

    private final class Socket: RealtimeSocket, @unchecked Sendable {
        private struct State {
            var inbox: [String] = []
            var waiter: CheckedContinuation<String, any Error>?
            var closed: TranscriptionLink.CloseReason?
            var audioMilliseconds = 0
            /// 讀的那個 task 被取消了：之後的 `receive` 直接以取消結束。
            var cancelled = false
        }

        private let owner: ReplayConnector
        private let index: Int
        private let fault: Fault?
        private let state = LockedValue(State())

        init(owner: ReplayConnector, index: Int, fault: Fault?) {
            self.owner = owner
            self.index = index
            self.fault = fault
            switch fault {
            case .refuse(let reason): shut(reason)
            case .silent: break
            default: deliver([owner.created()])
            }
        }

        func send(_ message: String) async throws {
            if state.value.closed != nil { throw RealtimeSocketClosed(reason: .lost) }
            let before = owner.receivedAudioSeconds
            _ = owner.record(message, index: index)
            if fault == .silent { return }
            if message.contains("\"session.update\"") {
                deliver([owner.configured()])
            } else if message.contains("input_audio_buffer.commit") {
                deliver(owner.due(untilCompletion: true))
            } else if message.contains("input_audio_buffer.append") {
                let added = Int(((owner.receivedAudioSeconds - before) * 1000).rounded())
                let total = state.withValue { state -> Int in
                    state.audioMilliseconds += added
                    return state.audioMilliseconds
                }
                deliver(owner.due(untilCompletion: false))
                if case .closeAfter(let limit, let reason) = fault, total >= limit { shut(reason) }
            }
        }

        func receive() async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    let ready: Result<String, any Error>? = state.withValue { state in
                        if state.cancelled { return .failure(CancellationError()) }
                        if !state.inbox.isEmpty { return .success(state.inbox.removeFirst()) }
                        if let reason = state.closed { return .failure(RealtimeSocketClosed(reason: reason)) }
                        state.waiter = continuation
                        return nil
                    }
                    if let ready { continuation.resume(with: ready) }
                }
            } onCancel: {
                let waiter = state.withValue { state -> CheckedContinuation<String, any Error>? in
                    state.cancelled = true
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume(throwing: CancellationError())
            }
        }

        func close() {
            owner.markClosed(index: index)
            shut(.lost)
        }

        private func deliver(_ messages: [String]) {
            for message in messages {
                let waiter = state.withValue { state -> CheckedContinuation<String, any Error>? in
                    guard state.closed == nil else { return nil }
                    if let waiter = state.waiter {
                        state.waiter = nil
                        return waiter
                    }
                    state.inbox.append(message)
                    return nil
                }
                waiter?.resume(returning: message)
            }
        }

        private func shut(_ reason: TranscriptionLink.CloseReason) {
            let waiter = state.withValue { state -> CheckedContinuation<String, any Error>? in
                guard state.closed == nil else { return nil }
                state.closed = reason
                defer { state.waiter = nil }
                // 還沒被取走的訊息先讓對方收完，再回報斷線
                return state.inbox.isEmpty ? state.waiter : nil
            }
            waiter?.resume(throwing: RealtimeSocketClosed(reason: reason))
        }
    }
}
