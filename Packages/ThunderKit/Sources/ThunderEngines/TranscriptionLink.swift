import Foundation
import ThunderCore

/// 轉錄連線的管理：什麼時候連線、送什麼、斷了怎麼辦（DESIGN.md 5.6.3 節）。
///
/// 這個型別只做決定，不碰網路：呼叫端把發生的事告訴它（收到音訊、收到伺服器的事件、連線斷了、時間到了），
/// 它回傳要做的事（`Effect`：建立連線、送出訊息、關閉連線、回報狀態……），由呼叫端去執行。
/// 時間是輸入（秒，只增不減），它自己不看時鐘。所以整套規則可以用錄下來的事件與假的時間測試。
///
/// 規則：
/// - **收到 `session.updated` 才送音訊。** 之前收到的音訊先留著（最多 `backlogDuration`），連上後一次補送；
///   留不下的部分丟掉最舊的，回報成原因為 `network` 的缺口。
/// - **平常不 commit**（每 commit 一次，模型就失去前後文）。只在這些時候送：音訊結束、音訊中斷超過
///   `audioGapBeforeCommit`（使用者暫停）、換線之前、距離上次 commit 超過 `commitInterval` 後的第一次停頓。
/// - **重新連線**：連線斷了（不管有沒有原因）就等一下再連，等待時間每次加倍（`backoffBase`、2 倍、4 倍……
///   最長 `backoffLimit`），連上之後歸零。API Key 無效、設定被拒絕不重試，回報失敗。
/// - **換線**：連線滿 `rotationAge` 之後，在下一次停頓時換一條新的：舊的 commit 收尾，等它把最後的文字送完
///   （最多 `completionTimeout`）才關；新的連上之前的音訊先留著。
/// - **閒置**：`idleClose` 沒有音訊就關閉連線，音訊恢復時再連。
public struct TranscriptionLink: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var settings = TranscriptionSettings()
        /// 沒連上的時候最多保留多久的音訊。
        public var backlogDuration: TimeInterval = 10
        public var backoffBase: TimeInterval = 1
        public var backoffLimit: TimeInterval = 30
        /// 退避時間的隨機抖動：實際等待時間是「基準 ×（1 ± jitter）」。0 表示不抖動。
        public var jitter: Double = 0.2
        /// 建立連線後這麼久還沒收到 `session.updated`，就當成連線失敗。
        public var connectTimeout: TimeInterval = 10
        /// 連線滿這麼久之後，在下一次停頓時換線。伺服器的上限是 60 分鐘。
        public var rotationAge: TimeInterval = 45 * 60
        /// 距離上次 commit 超過這麼久，在下一次停頓時 commit 一次。
        public var commitInterval: TimeInterval = 5 * 60
        /// 音訊中斷這麼久（使用者暫停），就把手上的語音 commit。
        public var audioGapBeforeCommit: TimeInterval = 1
        /// 這麼久沒有音訊就關閉連線。
        public var idleClose: TimeInterval = 5 * 60
        /// commit 之後最多等完成事件多久。
        public var completionTimeout: TimeInterval = 3
        /// 每送出這麼多秒的音訊，回報一次累計的計費秒數。
        public var billingReportInterval: TimeInterval = 10

        public init() {}
    }

    /// 連線為什麼斷了。
    public enum CloseReason: Sendable, Equatable {
        /// API Key 無效（HTTP 401，或伺服器以代碼 3000 關閉）。
        case unauthorized
        /// 請求過多（HTTP 429）。
        case rateLimited
        /// 其他：網路錯誤、伺服器直接切斷、逾時。
        case lost
    }

    public enum Effect: Sendable, Equatable {
        /// 建立一條新連線，編號是 `connection`（只增不減）。之後這條連線的事件都帶這個編號。
        case open(connection: Int)
        case send(connection: Int, message: String)
        case close(connection: Int)
        /// 轉錄出來的增量文字。
        case text(String)
        case status(EngineStatus)
        /// 沒有送到伺服器的音訊。
        case gap(AudioGap)
        /// 到目前為止送給伺服器的音訊長度（秒），也就是計費的依據。
        case billed(seconds: Double)
        /// 收尾完成：不會再有文字，也不需要再呼叫任何方法。
        case finished
    }

    private enum Phase: Equatable {
        case notStarted
        /// 連線建立中，等 `session.created`。
        case connecting(since: TimeInterval)
        /// 設定已經送出，等 `session.updated`。
        case configuring(since: TimeInterval)
        case live(since: TimeInterval)
        /// 等退避時間過去。
        case waiting(until: TimeInterval)
        /// 閒置：連線已經關閉，音訊恢復時再連。
        case idle
        case failed
        case finished
    }

    public let configuration: Configuration

    private var phase = Phase.notStarted
    /// 目前這條連線的編號；還沒有建立過是 0。
    private var connection = 0
    /// 連續失敗的次數，決定退避時間。
    private var failures = 0
    /// 還沒送出的音訊（沒連上的期間）。
    private var backlog: [AudioChunk] = []
    private var backlogSeconds: TimeInterval = 0
    /// 正在收尾的舊連線：commit 已經送出，等它把最後的文字送完。
    private var draining: (connection: Int, deadline: TimeInterval)?
    /// 目前這條連線上，上次 commit 之後又送了多少音訊。
    private var uncommittedSeconds: TimeInterval = 0
    private var lastCommitAt: TimeInterval = 0
    private var lastAudioAt: TimeInterval?
    /// 音訊結束了，等最後一段完成的期限。
    private var endingDeadline: TimeInterval?
    /// 音訊結束時還沒連上：連上、補送之後就收尾。
    private var endRequested = false
    private var sentSeconds: TimeInterval = 0
    private var lastBillingReport: TimeInterval = 0
    private var random: UInt64

    public init(configuration: Configuration = Configuration(), seed: UInt64 = 0x5DEE_CE66_D1CE_4E5B) {
        self.configuration = configuration
        random = seed
    }

    /// 下一個需要呼叫 `advance(to:)` 的時間；沒有就是 nil。
    public var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        switch phase {
        case .connecting(let since), .configuring(let since):
            deadlines.append(since + configuration.connectTimeout)
        case .waiting(let until):
            deadlines.append(until)
        case .live:
            if let lastAudioAt, endingDeadline == nil {
                if uncommittedSeconds > 0 { deadlines.append(lastAudioAt + configuration.audioGapBeforeCommit) }
                deadlines.append(lastAudioAt + configuration.idleClose)
            }
        case .notStarted, .idle, .failed, .finished:
            break
        }
        if let draining { deadlines.append(draining.deadline) }
        if let endingDeadline { deadlines.append(endingDeadline) }
        return deadlines.min()
    }

    /// 是不是已經結束（收尾完成或失敗）。
    public var isOver: Bool { phase == .finished || phase == .failed }

    /// 開始：建立第一條連線。按下開始的同時就呼叫，連線建好之前的音訊會先留著。
    public mutating func start(at now: TimeInterval) -> [Effect] {
        guard phase == .notStarted else { return [] }
        lastCommitAt = now
        return [.status(.connecting)] + open(at: now)
    }

    /// 收到一包要送給伺服器的音訊。
    public mutating func audio(_ chunk: AudioChunk, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard !isOver, !endRequested, endingDeadline == nil else { return effects }
        lastAudioAt = now
        switch phase {
        case .live:
            effects += send(chunk)
        case .idle:
            // 音訊恢復：重新連線，這一包先留著
            effects.append(.status(.connecting))
            effects += open(at: now)
            effects += keep(chunk)
        case .notStarted:
            effects += start(at: now)
            effects += keep(chunk)
        case .connecting, .configuring, .waiting:
            effects += keep(chunk)
        case .failed, .finished:
            break
        }
        return effects
    }

    /// 音訊結束（正常收尾）：送出最後的 commit，等這一段完成後回報 `.finished`。
    public mutating func audioEnded(at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard !isOver, endingDeadline == nil, !endRequested else { return effects }
        switch phase {
        case .live:
            effects += beginEnding(at: now)
        case .connecting, .configuring:
            // 還在連線：連上、補送之後再收尾（最多等到連線逾時）
            endRequested = true
        case .notStarted, .waiting, .idle:
            effects += discardBacklog(reason: .network)
            phase = .finished
            effects.append(.finished)
        case .failed, .finished:
            break
        }
        return effects
    }

    /// 停頓偵測回報了一次停頓。只在需要的時候 commit 或換線；平常什麼都不做。
    public mutating func pauseDetected(at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        guard case .live(let since) = phase, endingDeadline == nil else { return effects }
        if now - since >= configuration.rotationAge {
            // 換線：舊的 commit 收尾，等它把最後的文字送完才關；新的連上之前的音訊先留著
            let old = connection
            if uncommittedSeconds > 0 {
                effects.append(.send(connection: old, message: TranscriptionCommand.commit))
                // 之前如果還有一條在收尾，直接關掉
                if let previous = draining { effects.append(.close(connection: previous.connection)) }
                draining = (old, now + configuration.completionTimeout)
            } else {
                effects.append(.close(connection: old))
            }
            uncommittedSeconds = 0
            lastCommitAt = now
            effects += open(at: now)
        } else if now - lastCommitAt >= configuration.commitInterval, uncommittedSeconds > 0 {
            effects.append(.send(connection: connection, message: TranscriptionCommand.commit))
            uncommittedSeconds = 0
            lastCommitAt = now
        }
        return effects
    }

    /// 收到伺服器的事件。`connection` 是它來自哪一條連線。
    public mutating func received(_ event: TranscriptionEvent, connection source: Int, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        let isCurrent = source == connection
        let isDraining = source == draining?.connection
        guard isCurrent || isDraining, !isOver else { return effects }

        switch event {
        case .sessionCreated:
            guard isCurrent, case .connecting = phase else { break }
            phase = .configuring(since: now)
            effects.append(.send(connection: connection, message: TranscriptionCommand.sessionUpdate(configuration.settings)))

        case .sessionUpdated:
            guard isCurrent, case .configuring = phase else { break }
            phase = .live(since: now)
            failures = 0
            uncommittedSeconds = 0
            lastCommitAt = now
            let waiting = backlog
            backlog = []
            backlogSeconds = 0
            for chunk in waiting { effects += send(chunk) }
            effects.append(.status(.live))
            if endRequested {
                endRequested = false
                effects += beginEnding(at: now)
            }

        case .delta(_, let text):
            if !text.isEmpty { effects.append(.text(text)) }

        case .completed:
            if isDraining {
                effects.append(.close(connection: source))
                draining = nil
            } else if endingDeadline != nil {
                effects += finish()
            }

        case .error(let code, let message):
            guard isCurrent else { break }
            if code == "invalid_api_key" {
                effects += fail("API Key 無效")
            } else if case .configuring = phase {
                // 設定有任何一項不合法，整份設定都不生效：不能送音訊
                effects += fail("轉錄設定被拒絕：\(message)")
            } else if endingDeadline != nil {
                // 收尾時的錯誤（例如沒有音訊可以 commit）：不會再有完成事件
                effects += finish()
            }

        case .committed, .other:
            break
        }
        return effects
    }

    /// 連線斷了。
    public mutating func closed(connection source: Int, reason: CloseReason, at now: TimeInterval) -> [Effect] {
        var effects = advance(to: now)
        if source == draining?.connection {
            draining = nil
            return effects
        }
        guard source == connection, !isOver else { return effects }
        switch phase {
        case .connecting, .configuring, .live:
            break
        case .notStarted, .waiting, .idle, .failed, .finished:
            return effects
        }
        if reason == .unauthorized {
            effects += fail("API Key 無效")
            return effects
        }
        if endingDeadline != nil || endRequested {
            // 收尾途中斷線：不再重連，已經收到的文字就是全部
            effects += discardBacklog(reason: .network)
            endingDeadline = nil
            endRequested = false
            phase = .finished
            effects.append(.finished)
            return effects
        }
        effects += scheduleReconnect(at: now)
        return effects
    }

    /// 時間前進到 `now`：處理到期的事（退避結束、連線逾時、音訊中斷、閒置、等完成事件逾時）。
    public mutating func advance(to now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        if let current = draining, now >= current.deadline {
            effects.append(.close(connection: current.connection))
            draining = nil
        }
        if let deadline = endingDeadline, now >= deadline {
            // 完成事件遲到：不等了，以已經收到的增量文字為準
            effects += finish()
            return effects
        }
        switch phase {
        case .waiting(let until) where now >= until:
            effects += open(at: now)
        case .connecting(let since) where now - since >= configuration.connectTimeout,
            .configuring(let since) where now - since >= configuration.connectTimeout:
            effects.append(.close(connection: connection))
            if endRequested {
                endRequested = false
                effects += discardBacklog(reason: .network)
                phase = .finished
                effects.append(.finished)
            } else {
                effects += scheduleReconnect(at: now)
            }
        case .live:
            guard let lastAudioAt, endingDeadline == nil else { break }
            if now - lastAudioAt >= configuration.idleClose {
                effects.append(.close(connection: connection))
                phase = .idle
                uncommittedSeconds = 0
                effects.append(.status(.idle))
            } else if uncommittedSeconds > 0, now - lastAudioAt >= configuration.audioGapBeforeCommit {
                effects.append(.send(connection: connection, message: TranscriptionCommand.commit))
                uncommittedSeconds = 0
                lastCommitAt = now
            }
        default:
            break
        }
        return effects
    }

    // MARK: 內部

    private mutating func open(at now: TimeInterval) -> [Effect] {
        connection += 1
        phase = .connecting(since: now)
        return [.open(connection: connection)]
    }

    private mutating func send(_ chunk: AudioChunk) -> [Effect] {
        var effects: [Effect] = [.send(connection: connection, message: TranscriptionCommand.append(chunk))]
        uncommittedSeconds += chunk.duration
        sentSeconds += chunk.duration
        if sentSeconds - lastBillingReport >= configuration.billingReportInterval {
            lastBillingReport = sentSeconds
            effects.append(.billed(seconds: sentSeconds))
        }
        return effects
    }

    /// 還沒連上：先留著。留不下的丟掉最舊的，回報成缺口。
    private mutating func keep(_ chunk: AudioChunk) -> [Effect] {
        backlog.append(chunk)
        backlogSeconds += chunk.duration
        var dropped: AudioGap?
        while backlogSeconds > configuration.backlogDuration + 1e-9, backlog.count > 1 {
            let oldest = backlog.removeFirst()
            backlogSeconds -= oldest.duration
            if var gap = dropped {
                gap.to = oldest.endTime
                dropped = gap
            } else {
                dropped = AudioGap(from: oldest.startTime, to: oldest.endTime, reason: .network)
            }
        }
        return dropped.map { [.gap($0)] } ?? []
    }

    /// 把還沒送出的音訊全部記成缺口。
    private mutating func discardBacklog(reason: GapReason) -> [Effect] {
        guard let first = backlog.first, let last = backlog.last else { return [] }
        backlog = []
        backlogSeconds = 0
        return [.gap(AudioGap(from: first.startTime, to: last.endTime, reason: reason))]
    }

    private mutating func beginEnding(at now: TimeInterval) -> [Effect] {
        guard uncommittedSeconds > 0 else { return finish() }
        uncommittedSeconds = 0
        lastCommitAt = now
        endingDeadline = now + configuration.completionTimeout
        return [.send(connection: connection, message: TranscriptionCommand.commit)]
    }

    private mutating func finish() -> [Effect] {
        var effects: [Effect] = []
        if let current = draining {
            effects.append(.close(connection: current.connection))
            draining = nil
        }
        effects.append(.close(connection: connection))
        effects.append(.billed(seconds: sentSeconds))
        endingDeadline = nil
        phase = .finished
        effects.append(.finished)
        return effects
    }

    private mutating func fail(_ reason: String) -> [Effect] {
        var effects: [Effect] = [.close(connection: connection)]
        if let current = draining {
            effects.append(.close(connection: current.connection))
            draining = nil
        }
        effects += discardBacklog(reason: .engineStopped)
        endingDeadline = nil
        endRequested = false
        phase = .failed
        effects.append(.billed(seconds: sentSeconds))
        effects.append(.status(.failed(reason: reason)))
        return effects
    }

    private mutating func scheduleReconnect(at now: TimeInterval) -> [Effect] {
        let exponent = min(failures, 16)
        var delay = min(configuration.backoffLimit, configuration.backoffBase * Double(1 << exponent))
        if configuration.jitter > 0 {
            delay *= 1 + configuration.jitter * (2 * nextRandomUnit() - 1)
        }
        failures += 1
        uncommittedSeconds = 0
        phase = .waiting(until: now + delay)
        return [.status(.reconnecting)]
    }

    /// 0..<1 的亂數（固定的種子，所以同樣的輸入會得到同樣的結果）。
    private mutating func nextRandomUnit() -> Double {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(random >> 11) / Double(1 << 53)
    }
}
