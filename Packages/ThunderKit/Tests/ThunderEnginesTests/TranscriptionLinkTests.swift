import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 把 `TranscriptionLink` 回傳的動作收集起來，方便檢查。
private struct LinkDriver {
    var link: TranscriptionLink
    private(set) var effects: [TranscriptionLink.Effect] = []

    init(_ configure: (inout TranscriptionLink.Configuration) -> Void = { _ in }) {
        var configuration = TranscriptionLink.Configuration()
        configuration.jitter = 0  // 測試要確切的時間；抖動另外測
        configure(&configuration)
        link = TranscriptionLink(configuration: configuration)
    }

    @discardableResult
    mutating func run(_ new: [TranscriptionLink.Effect]) -> [TranscriptionLink.Effect] {
        effects += new
        return new
    }

    /// 一包 0.2 秒的音訊。內容只有兩個樣本（第一個是編號），長度靠很低的取樣率湊出來，長時間的測試才不會占記憶體。
    static func chunk(_ index: Int) -> AudioChunk {
        var data = Data()
        for value in [Int16(index % 30_000), Int16(index / 30_000)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return AudioChunk(pcm16: data, sampleRate: 10, startTime: AudioTime(seconds: Double(index) * 0.2))
    }

    @discardableResult
    mutating func audio(_ index: Int, at now: TimeInterval) -> [TranscriptionLink.Effect] {
        run(link.audio(Self.chunk(index), at: now))
    }

    /// 走完連線與設定：`session.created`、`session.updated`。
    mutating func goLive(connection: Int, at now: TimeInterval) {
        run(link.received(.sessionCreated, connection: connection, at: now))
        run(link.received(.sessionUpdated, connection: connection, at: now))
    }

    var opened: [Int] {
        effects.compactMap { if case .open(let connection) = $0 { connection } else { nil } }
    }

    var closed: [Int] {
        effects.compactMap { if case .close(let connection) = $0 { connection } else { nil } }
    }

    func sent(on connection: Int? = nil) -> [String] {
        effects.compactMap {
            if case .send(let target, let message) = $0, connection == nil || connection == target { message } else { nil }
        }
    }

    /// 送出的音訊包的編號，依送出的順序。
    func appended(on connection: Int? = nil) -> [Int] {
        sent(on: connection).compactMap { message in
            guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                object["type"] as? String == "input_audio_buffer.append",
                let audio = object["audio"] as? String, let data = Data(base64Encoded: audio), data.count == 4
            else { return nil }
            let low = Int(Int16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }))
            let high = Int(Int16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Int16.self) }))
            return high * 30_000 + low
        }
    }

    func commits(on connection: Int? = nil) -> Int {
        sent(on: connection).filter { $0 == TranscriptionCommand.commit }.count
    }

    var text: String {
        effects.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    var statuses: [EngineStatus] {
        effects.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }

    var gaps: [AudioGap] {
        effects.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }
    }

    var billed: Double? {
        effects.compactMap { if case .billed(let seconds) = $0 { seconds } else { nil } }.last
    }

    var finished: Bool { effects.contains(.finished) }

    var failureReason: String? {
        statuses.compactMap { if case .failed(let reason) = $0 { reason } else { nil } }.last
    }
}

@Suite("轉錄連線：連線與設定")
struct TranscriptionLinkSetupTests {
    @Test("開始就建立連線；收到 session.created 才送設定；收到 session.updated 之前不送音訊，之後依序補送")
    func configuresBeforeSendingAudio() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        #expect(driver.opened == [1])
        #expect(driver.statuses == [.connecting])

        driver.audio(0, at: 0.2)
        driver.audio(1, at: 0.4)
        #expect(driver.sent().isEmpty, "還沒連上，什麼都不能送")

        driver.run(driver.link.received(.sessionCreated, connection: 1, at: 0.45))
        #expect(driver.sent() == [TranscriptionCommand.sessionUpdate(driver.link.configuration.settings)])

        driver.audio(2, at: 0.6)
        #expect(driver.appended().isEmpty, "設定還沒被接受，不能送音訊")

        driver.run(driver.link.received(.sessionUpdated, connection: 1, at: 0.7))
        #expect(driver.appended() == [0, 1, 2])
        #expect(driver.statuses == [.connecting, .live])

        driver.audio(3, at: 0.8)
        #expect(driver.appended() == [0, 1, 2, 3], "連上之後立刻送出")
    }

    @Test("設定被拒絕（重播錄下的事件）：回報失敗、不送音訊，留著的音訊記成缺口")
    func rejectedSettings() throws {
        let fixture = try RealtimeFixture.load("rejected-delay")
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.audio(0, at: 0.2)
        for line in fixture.serverLines {
            driver.run(driver.link.received(try recordedEvent(line), connection: 1, at: 0.3))
        }

        #expect(driver.appended().isEmpty)
        #expect(driver.closed == [1])
        #expect(driver.link.isOver)
        let reason = try #require(driver.failureReason)
        #expect(reason.contains("bogus"), "要把伺服器說的原因帶給使用者：\(reason)")
        #expect(driver.gaps == [AudioGap(from: .zero, to: AudioTime(seconds: 0.2), reason: .engineStopped)])

        // 失敗之後不再做任何事
        #expect(driver.audio(1, at: 0.4).isEmpty)
        #expect(driver.run(driver.link.advance(to: 100)).isEmpty)
        #expect(driver.link.nextDeadline == nil)
        #expect(driver.opened == [1])
    }

    @Test("API Key 無效：不重試，回報失敗", arguments: [true, false])
    func invalidKey(reportedAsEvent: Bool) {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        if reportedAsEvent {
            // 實測：連線成功後收到 error 事件，接著伺服器以代碼 3000 關閉
            driver.run(driver.link.received(.sessionCreated, connection: 1, at: 0.1))
            driver.run(driver.link.received(.error(code: "invalid_api_key", message: "Incorrect API key provided"), connection: 1, at: 0.2))
        }
        driver.run(driver.link.closed(connection: 1, reason: .unauthorized, at: 0.3))

        #expect(driver.failureReason != nil)
        #expect(driver.link.isOver)
        driver.run(driver.link.advance(to: 600))
        #expect(driver.opened == [1], "Key 無效時重試沒有意義")
        #expect(!driver.statuses.contains(.reconnecting))
    }

    @Test("連線後 10 秒沒有完成設定就重來", arguments: [false, true])
    func connectTimeout(createdArrives: Bool) {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        if createdArrives { driver.run(driver.link.received(.sessionCreated, connection: 1, at: 1)) }
        let deadline: TimeInterval = createdArrives ? 11 : 10
        #expect(driver.link.nextDeadline == deadline)

        driver.run(driver.link.advance(to: deadline - 0.01))
        #expect(driver.closed.isEmpty)
        driver.run(driver.link.advance(to: deadline))
        #expect(driver.closed == [1])
        #expect(driver.statuses.last == .reconnecting)

        driver.run(driver.link.advance(to: deadline + 1))
        #expect(driver.opened == [1, 2])
    }
}

@Suite("轉錄連線：commit 只在必要時送")
struct TranscriptionLinkCommitTests {
    @Test("重播 keynote：停頓時不 commit；文字原樣送出；音訊結束才 commit，收到完成事件後結束")
    func replayWithoutCommits() throws {
        let fixture = try RealtimeFixture.load("keynote-single-turn")
        let transcript = try TranscriptFixture.load(events: "keynote-single-turn", audio: "keynote")
        let audioEnd = try #require(transcript.sentences.last).end
        var pauses = transcript.pauses[...]
        var lines = fixture.serverLines.filter { $0.receivedAt != nil }[...]

        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)

        var index = 0
        while Double(index) * 0.2 < audioEnd {
            let now = Double(index + 1) * 0.2
            while let line = lines.first, let at = line.receivedAt, at <= now {
                driver.run(driver.link.received(try recordedEvent(line), connection: 1, at: at))
                lines.removeFirst()
            }
            while let pause = pauses.first, pause.detectedAt <= now {
                driver.run(driver.link.pauseDetected(at: pause.detectedAt))
                pauses.removeFirst()
            }
            driver.audio(index, at: now)
            index += 1
        }
        #expect(transcript.pauses.count >= 15)
        #expect(driver.commits() == 0, "講者停頓時不 commit：每 commit 一次模型就失去前後文")
        #expect(!driver.finished)

        let end = Double(index) * 0.2
        driver.run(driver.link.audioEnded(at: end))
        #expect(driver.commits() == 1)
        #expect(!driver.finished, "要等最後一段完成")

        // 剩下的事件（最後幾個字與完成事件）在 commit 之後才到
        for line in lines {
            driver.run(driver.link.received(try recordedEvent(line), connection: 1, at: end + 0.5))
        }
        #expect(driver.finished)
        #expect(driver.closed == [1])
        #expect(driver.text == transcript.text)
        #expect(driver.appended() == Array(0..<index))
        #expect(driver.opened == [1])
    }

    @Test("距離上次 commit 超過 5 分鐘後的第一次停頓會 commit 一次，之後重新計時")
    func periodicCommit() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        var index = 0
        func feed(until time: TimeInterval, _ driver: inout LinkDriver, _ index: inout Int) {
            while Double(index + 1) * 0.2 <= time {
                driver.audio(index, at: Double(index + 1) * 0.2)
                index += 1
            }
        }

        feed(until: 100, &driver, &index)
        driver.run(driver.link.pauseDetected(at: 100))
        feed(until: 299, &driver, &index)
        driver.run(driver.link.pauseDetected(at: 299))
        #expect(driver.commits() == 0)

        feed(until: 301, &driver, &index)
        driver.run(driver.link.pauseDetected(at: 301))
        #expect(driver.commits() == 1)

        feed(until: 330, &driver, &index)
        driver.run(driver.link.pauseDetected(at: 330))
        #expect(driver.commits() == 1, "剛 commit 過，重新計時")

        feed(until: 602, &driver, &index)
        driver.run(driver.link.pauseDetected(at: 602))
        #expect(driver.commits() == 2)
        #expect(driver.opened == [1])
    }

    @Test("音訊中斷超過 1 秒（使用者暫停）就把手上的語音 commit；沒有新的音訊不會重複 commit")
    func commitsWhenAudioStops() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        for index in 0..<10 { driver.audio(index, at: Double(index + 1) * 0.2) }

        #expect(driver.link.nextDeadline == 3.0)
        driver.run(driver.link.advance(to: 2.9))
        #expect(driver.commits() == 0)
        driver.run(driver.link.advance(to: 3.0))
        #expect(driver.commits() == 1)
        driver.run(driver.link.advance(to: 60))
        #expect(driver.commits() == 1)

        // 繼續錄：再中斷一次，再 commit 一次
        driver.audio(10, at: 70)
        driver.run(driver.link.advance(to: 71))
        #expect(driver.commits() == 2)
        #expect(driver.closed.isEmpty)
    }

    @Test("完成事件遲到：等 3 秒就結束，不會卡住；之後才到的事件不再有作用")
    func lateCompletion() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        driver.audio(0, at: 0.2)
        driver.run(driver.link.audioEnded(at: 0.4))
        #expect(driver.commits() == 1)
        #expect(driver.link.nextDeadline == 3.4)

        driver.run(driver.link.advance(to: 3.3))
        #expect(!driver.finished)
        driver.run(driver.link.advance(to: 3.4))
        #expect(driver.finished)
        #expect(driver.closed == [1])

        let late = driver.run(driver.link.received(.completed(itemID: "item", transcript: "late", billedSeconds: 1), connection: 1, at: 7))
        #expect(late.isEmpty)
    }

    @Test("音訊結束時還在連線中：連上、補送、commit 之後才結束")
    func endsWhileConnecting() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.audio(0, at: 0.2)
        driver.audio(1, at: 0.4)
        driver.run(driver.link.audioEnded(at: 0.5))
        #expect(!driver.finished)

        driver.goLive(connection: 1, at: 0.7)
        #expect(driver.appended() == [0, 1])
        #expect(driver.commits() == 1)
        #expect(!driver.finished)

        driver.run(driver.link.received(.completed(itemID: "item", transcript: "hello", billedSeconds: 1), connection: 1, at: 1.2))
        #expect(driver.finished)
        #expect(driver.closed == [1])
    }

    @Test("沒有送過任何音訊就結束：不 commit，直接結束")
    func endsWithoutAudio() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0.3)
        driver.run(driver.link.audioEnded(at: 1))
        #expect(driver.commits() == 0)
        #expect(driver.finished)
        #expect(driver.closed == [1])
    }

    @Test("累計的計費秒數等於送給伺服器的音訊長度")
    func billedSeconds() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        for index in 0..<120 { driver.audio(index, at: Double(index + 1) * 0.2) }
        // 每送出約 10 秒的音訊回報一次
        #expect(abs((driver.billed ?? 0) - 20) < 0.5)
        driver.run(driver.link.audioEnded(at: 24.2))
        driver.run(driver.link.received(.completed(itemID: "item", transcript: "", billedSeconds: 24), connection: 1, at: 24.7))
        #expect(abs((driver.billed ?? 0) - 24) < 1e-6)
    }
}

@Suite("轉錄連線：重新連線、換線、閒置")
struct TranscriptionLinkRecoveryTests {
    @Test("斷線後依 1、2、4、8、16、30、30 秒重試；連上之後歸零")
    func backoff() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)

        var now: TimeInterval = 10
        var connection = 1
        for expected in [1.0, 2, 4, 8, 16, 30, 30] {
            driver.run(driver.link.closed(connection: connection, reason: .lost, at: now))
            #expect(driver.link.nextDeadline == now + expected)
            driver.run(driver.link.advance(to: now + expected - 0.01))
            #expect(driver.opened.last == connection, "還沒到時間，不能重連")
            now += expected
            driver.run(driver.link.advance(to: now))
            connection += 1
            #expect(driver.opened.last == connection)
            now += 0.5
        }
        #expect(!driver.statuses.contains { if case .failed = $0 { true } else { false } })

        driver.goLive(connection: connection, at: now)
        #expect(driver.statuses.last == .live)
        driver.run(driver.link.closed(connection: connection, reason: .lost, at: now + 5))
        #expect(driver.link.nextDeadline == now + 5 + 1, "連上過，退避時間歸零")
    }

    @Test("連線無預警斷掉、請求過多：都是退避後重新連線，不算失敗", arguments: [TranscriptionLink.CloseReason.lost, .rateLimited])
    func ordinaryReconnect(reason: TranscriptionLink.CloseReason) {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        driver.audio(0, at: 0.2)
        driver.run(driver.link.closed(connection: 1, reason: reason, at: 0.5))

        #expect(driver.statuses == [.connecting, .live, .reconnecting])
        #expect(!driver.link.isOver)
        driver.run(driver.link.advance(to: 1.5))
        #expect(driver.opened == [1, 2])
        driver.goLive(connection: 2, at: 1.8)
        #expect(driver.statuses.last == .live)
    }

    @Test("斷線期間的音訊留 10 秒，連上後依序補送；更早的記成缺口，兩者加起來一包不少")
    func backlogAndGaps() {
        var driver = LinkDriver { $0.connectTimeout = 100 }
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        for index in 0..<5 { driver.audio(index, at: Double(index + 1) * 0.2) }
        driver.run(driver.link.closed(connection: 1, reason: .lost, at: 1.0))

        // 斷線 15 秒（75 包）
        for index in 5..<80 { driver.audio(index, at: Double(index + 1) * 0.2) }
        #expect(driver.opened == [1, 2], "退避 1 秒後就開始重連")
        #expect(driver.appended() == Array(0..<5))

        driver.goLive(connection: 2, at: 16.1)
        #expect(driver.appended(on: 2) == Array(30..<80), "補送最近 10 秒，順序不變")
        let gaps = AudioGap.coalesced(driver.gaps)
        #expect(gaps.count == 1)
        #expect(gaps.first?.reason == .network)
        #expect(abs((gaps.first?.from.seconds ?? -1) - 1.0) < 1e-9)
        #expect(abs((gaps.first?.to.seconds ?? -1) - 6.0) < 1e-9)
        #expect(driver.statuses.last == .live)
    }

    @Test("滿 45 分鐘後的第一次停頓換線：舊連線 commit 收尾，新連線接手，音訊不遺失也不重複")
    func rotation() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        var index = 0
        while Double(index + 1) * 0.2 <= 2_700.2 {
            driver.audio(index, at: Double(index + 1) * 0.2)
            index += 1
        }
        #expect(driver.opened == [1])

        let rotated = driver.run(driver.link.pauseDetected(at: 2_700.3))
        #expect(rotated == [.send(connection: 1, message: TranscriptionCommand.commit), .open(connection: 2)])
        #expect(!driver.statuses.contains(.reconnecting), "換線是計畫中的事，畫面不需要知道")

        // 新連線連上之前：音訊先留著；舊連線還在送最後幾個字
        driver.audio(index, at: 2_700.4)
        #expect(driver.appended().count == index)
        driver.run(driver.link.received(.delta(itemID: "old", text: " tail"), connection: 1, at: 2_700.5))
        #expect(driver.text == " tail")

        driver.goLive(connection: 2, at: 2_700.6)
        #expect(driver.appended(on: 2) == [index])
        driver.audio(index + 1, at: 2_700.8)
        #expect(driver.appended(on: 2) == [index, index + 1])

        driver.run(driver.link.received(.completed(itemID: "old", transcript: "…", billedSeconds: 2_701), connection: 1, at: 2_701))
        #expect(driver.closed == [1])
        #expect(driver.appended() == Array(0...(index + 1)), "每一包恰好送出一次")
        #expect(!driver.finished)
    }

    @Test("換線時舊連線的完成事件沒有來：等 3 秒就關掉舊連線")
    func rotationWithoutCompletion() {
        var driver = LinkDriver { $0.rotationAge = 10 }
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        for index in 0..<55 { driver.audio(index, at: Double(index + 1) * 0.2) }
        driver.run(driver.link.pauseDetected(at: 11))
        driver.goLive(connection: 2, at: 11.3)
        #expect(driver.closed.isEmpty)
        driver.run(driver.link.advance(to: 14))
        #expect(driver.closed == [1])
        #expect(driver.statuses.last == .live)
    }

    @Test("閒置 5 分鐘關閉連線；音訊恢復時重新連線並補送")
    func idle() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        for index in 0..<5 { driver.audio(index, at: Double(index + 1) * 0.2) }

        driver.run(driver.link.advance(to: 2))
        #expect(driver.commits() == 1)
        driver.run(driver.link.advance(to: 300.9))
        #expect(driver.closed.isEmpty)
        driver.run(driver.link.advance(to: 301))
        #expect(driver.closed == [1])
        #expect(driver.statuses.last == .idle)
        #expect(driver.link.nextDeadline == nil, "閒置時不留任何計時")

        // 自己關掉的連線回報關閉，不當成斷線
        driver.run(driver.link.closed(connection: 1, reason: .lost, at: 301.1))
        #expect(driver.statuses.last == .idle)

        driver.audio(5, at: 400)
        #expect(driver.opened == [1, 2])
        #expect(driver.statuses.last == .connecting)
        driver.goLive(connection: 2, at: 400.3)
        #expect(driver.appended(on: 2) == [5])
        #expect(driver.statuses.last == .live)
    }

    @Test("收尾途中斷線：直接結束，不再重連")
    func closedWhileEnding() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        driver.audio(0, at: 0.2)
        driver.run(driver.link.audioEnded(at: 0.4))
        driver.run(driver.link.closed(connection: 1, reason: .lost, at: 0.6))

        #expect(driver.finished)
        driver.run(driver.link.advance(to: 60))
        #expect(driver.opened == [1])
    }

    @Test("已經換掉的舊連線送來的事件會被忽略")
    func staleConnection() {
        var driver = LinkDriver()
        driver.run(driver.link.start(at: 0))
        driver.goLive(connection: 1, at: 0)
        driver.run(driver.link.closed(connection: 1, reason: .lost, at: 5))
        driver.run(driver.link.advance(to: 6))
        driver.goLive(connection: 2, at: 6.3)
        let before = driver.effects.count

        driver.run(driver.link.received(.delta(itemID: "old", text: " ghost"), connection: 1, at: 7))
        driver.run(driver.link.closed(connection: 1, reason: .lost, at: 7))
        driver.run(driver.link.received(.sessionUpdated, connection: 1, at: 7))

        #expect(driver.effects.count == before)
        #expect(driver.text.isEmpty)
        #expect(driver.statuses.last == .live)
    }

    @Test("退避時間有隨機抖動：落在基準的 ±20% 之內，而且不是每次都一樣")
    func jitter() {
        var delays: Set<Double> = []
        for seed in UInt64(1)...40 {
            var link = TranscriptionLink(configuration: TranscriptionLink.Configuration(), seed: seed)
            _ = link.start(at: 0)
            _ = link.closed(connection: 1, reason: .lost, at: 0)
            let delay = link.nextDeadline ?? -1
            #expect(delay >= 0.8 && delay <= 1.2)
            delays.insert((delay * 1_000).rounded())
        }
        #expect(delays.count > 10)
    }
}
