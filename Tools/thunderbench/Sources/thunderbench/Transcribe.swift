import Foundation

/// 記錄純轉錄連線收到的每一個事件與時間。接收與傳送在不同的 task，所以用鎖保護。
final class TranscriptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let clock = ContinuousClock()
    private let connectedAt: ContinuousClock.Instant
    private var audioStartedAt: ContinuousClock.Instant?
    private var sentMs = 0

    private var counts: [String: Int] = [:]
    private var itemOrder: [String] = []
    private var deltaText: [String: String] = [:]
    private var finalText: [String: String] = [:]
    private var firstDeltaMs: Int?
    private var errors: [String] = []
    private var sessionCreated: [String: Any]?
    private var sessionUpdated: [String: Any]?
    private var disconnect: [String: Any]?
    private var usageSeconds = 0.0
    private var usageSamples: [[String: Any]] = []
    private var committed = 0
    private var finished = 0
    private var failed = 0
    private var downstreamBytes = 0

    init(file: FileHandle) {
        self.file = file
        self.connectedAt = clock.now
    }

    private func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let elapsed = clock.now - instant
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func markAudioStart() { lock.withLock { audioStartedAt = clock.now } }
    func setSent(milliseconds: Int) { lock.withLock { sentMs = milliseconds } }
    var sinceConnectMs: Int { milliseconds(since: connectedAt) }
    var isDisconnected: Bool { lock.withLock { disconnect != nil } }
    var hasSessionUpdated: Bool { lock.withLock { sessionUpdated != nil } }
    var hasSessionCreated: Bool { lock.withLock { sessionCreated != nil } }
    var errorCount: Int { lock.withLock { errors.count } }
    /// 已經有結果（完成或失敗）的段數。
    var settledItems: Int { lock.withLock { finished + failed } }

    private func track(_ item: String) {
        if deltaText[item] == nil, finalText[item] == nil { itemOrder.append(item) }
    }

    func record(_ raw: String) {
        lock.withLock {
            let rx = audioStartedAt.map { milliseconds(since: $0) }
            downstreamBytes += raw.utf8.count
            guard let event = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                file.write(jsonLine(["sent_ms": sentMs, "unparsed": redact(String(raw.prefix(500)))]))
                return
            }
            let type = event["type"] as? String ?? "?"
            counts[type, default: 0] += 1
            let item = event["item_id"] as? String ?? "?"
            switch type {
            case "conversation.item.input_audio_transcription.delta":
                track(item)
                deltaText[item, default: ""] += event["delta"] as? String ?? ""
                if firstDeltaMs == nil, let rx { firstDeltaMs = rx }
            case "conversation.item.input_audio_transcription.completed":
                track(item)
                finalText[item] = event["transcript"] as? String ?? ""
                finished += 1
                if let usage = event["usage"] as? [String: Any] {
                    if let seconds = usage["seconds"] as? Double { usageSeconds += seconds }
                    if usageSamples.count < 5 { usageSamples.append(usage) }
                }
            case "conversation.item.input_audio_transcription.failed":
                failed += 1
                errors.append(redact(raw))
            case "input_audio_buffer.committed":
                committed += 1
            case "session.created", "transcription_session.created":
                sessionCreated = event
            case "session.updated", "transcription_session.updated":
                sessionUpdated = event
            case "error":
                errors.append(redact(raw))
            default:
                break
            }
            var line: [String: Any] = ["sent_ms": sentMs, "since_connect_ms": milliseconds(since: connectedAt), "event": event]
            if let rx { line["rx_ms"] = rx }
            file.write(jsonLine(line))
        }
    }

    /// 到目前為止收到的文字的最後 `count` 個字元（依段的順序接起來）。
    func transcriptTail(_ count: Int) -> String {
        lock.withLock {
            let all = itemOrder.map { deltaText[$0] ?? "" }.joined(separator: " ")
            return String(all.suffix(count))
        }
    }

    /// 記下用戶端自己做的事（例如送出 commit），和收到的事件用同一條時間軸。
    func note(_ action: String, _ extra: [String: Any] = [:]) {
        lock.withLock {
            var line: [String: Any] = ["client": action, "sent_ms": sentMs, "since_connect_ms": milliseconds(since: connectedAt)]
            if let audioStartedAt { line["rx_ms"] = milliseconds(since: audioStartedAt) }
            for (key, value) in extra { line[key] = value }
            file.write(jsonLine(line))
        }
    }

    func noteDisconnect(error: String, closeCode: Int, reason: String?) {
        lock.withLock {
            guard disconnect == nil else { return }
            disconnect = [
                "error": redact(error), "close_code": closeCode, "reason": reason ?? "",
                "since_connect_ms": milliseconds(since: connectedAt), "sent_ms": sentMs,
            ]
        }
    }

    func snapshot() -> [String: Any] {
        lock.withLock {
            let items: [[String: Any]] = itemOrder.map {
                ["item_id": $0, "delta_text": deltaText[$0] ?? "", "final_text": finalText[$0] as Any]
            }
            return [
                "event_counts": counts, "first_delta_ms": firstDeltaMs as Any, "errors": errors,
                "disconnect": disconnect as Any, "session_created": sessionCreated as Any,
                "session_updated": sessionUpdated as Any, "items": items,
                "delta_text": itemOrder.map { deltaText[$0] ?? "" }.joined(),
                "final_text": itemOrder.map { finalText[$0] ?? "" }.joined(separator: " "),
                "usage_seconds": usageSeconds, "usage_samples": usageSamples,
                "committed_items": committed, "completed_items": finished, "failed_items": failed,
                "downstream_bytes": downstreamBytes,
            ]
        }
    }
}

/// 何時把目前這一段音訊送出（commit）。gpt-live-transcribe 沒有伺服器端的斷句，要由用戶端決定。
enum CommitMode {
    /// 全部送完才 commit 一次。
    case atEnd
    /// 每隔固定秒數 commit 一次（不管是否正在說話）。
    case interval(Double)
    /// 說話之後出現這麼長的靜音就 commit（用戶端的簡易語音偵測）。
    case silence(Int)
    /// 照事先算好的位置 commit（音訊位置，毫秒，由小到大）。用來試各種停頓偵測的做法，位置由 vad-plan.py 產生。
    case plan([Int])

    init(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "none", "end": self = .atEnd
        case "interval": self = .interval(parts.count > 1 ? Double(parts[1]) ?? 10 : 10)
        case "silence": self = .silence(parts.count > 1 ? Int(parts[1]) ?? 300 : 300)
        case "plan":
            guard parts.count > 1, let text = try? String(contentsOf: URL(fileURLWithPath: parts[1]), encoding: .utf8) else {
                fail("--commit plan:<檔案> 讀不到檔案")
            }
            self = .plan(text.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.sorted())
        default: fail("--commit 只接受 none、interval:<秒>、silence:<毫秒>、plan:<檔案>")
        }
    }
}

/// 把音檔串流到純轉錄的 Realtime 連線（預設 gpt-live-transcribe），錄下所有事件。會產生 API 費用。
func transcribe(_ arguments: Arguments) async throws {
    let noAudio = arguments.flags.contains("no-audio")
    guard let outPath = arguments.options["out"], noAudio || arguments.positional.count >= 2 else {
        fail("用法：thunderbench transcribe <音檔.wav> --out <資料夾> [選項]　或　thunderbench transcribe --no-audio --out <資料夾> [選項]")
    }
    let audio = noAudio ? WavAudio(sampleRate: 24_000, samples: []) : try WavAudio.read(URL(fileURLWithPath: arguments.positional[1]))
    guard audio.sampleRate == 24_000 else { fail("音檔必須是 24 kHz（目前 \(audio.sampleRate)）") }

    let model = arguments.string("model", default: "gpt-live-transcribe")
    let chunkMs = arguments.int("chunk-ms", default: 200)
    let speed = arguments.double("speed", default: 1)
    let loopMinutes = arguments.double("loop-minutes", default: 0)
    let commitMode = CommitMode(arguments.string("commit", default: "none"))
    /// 一段超過這麼多秒還沒有 commit 就強制 commit（0＝不限制）。
    let maxTurnSeconds = arguments.double("max-turn", default: 0)
    let vadThreshold = arguments.double("vad-threshold", default: 100)
    let finalWait = arguments.double("final-wait", default: 20)
    let noise = arguments.string("noise-reduction", default: "none")
    /// 每次 commit 之後，把目前逐字稿的最後這麼多個字元放進 prompt（0＝不做）。
    /// 每一段是各自辨識的；這是在試「把前文當成提示」能不能補回上下文。
    let rollingPrompt = arguments.int("rolling-prompt", default: 0)
    /// 音訊送完、最後一段也完成之後，保持連線但不送音訊這麼多分鐘（測試閒置與到期的行為）。
    let holdMinutes = arguments.double("hold-minutes", default: 0)

    // 設定
    var transcription: [String: Any] = ["model": model]
    if let delay = arguments.options["delay"] { transcription["delay"] = delay }
    if let prompt = arguments.options["prompt"] { transcription["prompt"] = prompt }
    if let languages = arguments.options["languages"] {
        transcription["languages"] = languages.split(separator: ",").map { String($0) }
    }
    if let language = arguments.options["language"] { transcription["language"] = language }
    if let keywordsPath = arguments.options["keywords"] {
        let text = try String(contentsOf: URL(fileURLWithPath: keywordsPath), encoding: .utf8)
        transcription["keywords"] = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    var input: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24_000], "transcription": transcription]
    if !arguments.flags.contains("omit-turn-detection") { input["turn_detection"] = NSNull() }
    if noise != "none" { input["noise_reduction"] = ["type": noise] }
    var session: [String: Any] = ["type": "transcription", "audio": ["input": input]]
    // 探索用：直接指定整個 session 物件（JSON），用來試哪些設定會被拒絕
    if let raw = arguments.options["session-json"] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            fail("--session-json 不是合法的 JSON 物件")
        }
        session = object
    }

    let outDirectory = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let eventsURL = outDirectory.appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    let recorder = TranscriptRecorder(file: try FileHandle(forWritingTo: eventsURL))

    let query = arguments.string("url-query", default: "intent=transcription")
    var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?\(query)")!)
    request.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.maximumMessageSize = 32 << 20
    let clock = ContinuousClock()
    let connectStarted = clock.now
    socket.resume()

    let receiver = Task {
        while true {
            do {
                switch try await socket.receive() {
                case .string(let text): recorder.record(text)
                case .data(let data): recorder.record(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) }
                recorder.noteDisconnect(error: "\(error)", closeCode: socket.closeCode.rawValue, reason: reason)
                break
            }
        }
    }

    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
    func waitUntil(_ timeout: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = clock.now + .milliseconds(Int(timeout * 1000))
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // 等 session.created，再送設定，等 session.updated（或錯誤）
    var sendError: String?
    _ = try await waitUntil(10) { recorder.hasSessionCreated || recorder.isDisconnected || recorder.errorCount > 0 }
    let createdMs = milliseconds(clock.now - connectStarted)
    let updateSent = clock.now
    do {
        try await send(["type": "session.update", "session": session])
    } catch {
        sendError = redact("session.update 送不出去：\(error)")
    }
    let configured = try await waitUntil(8) { recorder.hasSessionUpdated || recorder.isDisconnected || recorder.errorCount > 0 }
    let updatedMs = milliseconds(clock.now - updateSent)
    let accepted = recorder.hasSessionUpdated
    if !configured { print("8 秒內沒有收到 session.updated 或錯誤") }

    // 以即時速度（或 --speed 倍速）送出音訊
    let pcm = audio.pcmData
    let bytesPerChunk = 48 * chunkMs
    let frameBytes = 48 * 20
    let targetSeconds = loopMinutes > 0 ? loopMinutes * 60 : audio.duration
    var offset = 0
    var sentBytes = 0
    var lastCommitBytes = 0
    var commits = 0
    var speechSinceCommit = false
    var silenceRunMs = 0
    var planIndex = 0
    var nextProgress = 300.0
    recorder.markAudioStart()
    let started = clock.now

    func rms(_ frame: Data) -> Double {
        let count = frame.count / 2
        guard count > 0 else { return 0 }
        let sum: Double = frame.withUnsafeBytes { raw in
            var total = 0.0
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                total += sample * sample
            }
            return total
        }
        return (sum / Double(count)).squareRoot()
    }
    func append(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
        sentBytes += data.count
        recorder.setSent(milliseconds: sentBytes / 48)
    }
    func commit(_ reason: String) async throws {
        try await send(["type": "input_audio_buffer.commit"])
        commits += 1
        recorder.note("commit", ["reason": reason, "turn_seconds": Double(sentBytes - lastCommitBytes) / 48_000, "index": commits])
        lastCommitBytes = sentBytes
        speechSinceCommit = false
        if rollingPrompt > 0 {
            // 給伺服器一點時間把這一段的文字送回來，再用它更新 prompt（下一段已經開始送，所以只等很短的時間）
            let tail = recorder.transcriptTail(rollingPrompt)
            if !tail.isEmpty, var updated = session["audio"] as? [String: Any], var input = updated["input"] as? [String: Any],
               var transcription = input["transcription"] as? [String: Any] {
                let base = arguments.options["prompt"].map { $0 + " " } ?? ""
                transcription["prompt"] = String((base + "Previous transcript: " + tail).suffix(1000))
                input["transcription"] = transcription
                updated["input"] = input
                var next = session
                next["audio"] = updated
                try await send(["type": "session.update", "session": next])
                recorder.note("prompt-update", ["chars": tail.count])
            }
        }
    }

    if !noAudio, accepted || arguments.flags.contains("send-anyway") {
        do {
            while Double(sentBytes) / 48_000 < targetSeconds - 0.0005, !recorder.isDisconnected {
                let end = min(offset + bytesPerChunk, pcm.count)
                let chunk = pcm.subdata(in: offset..<end)
                offset = end >= pcm.count ? 0 : end

                // 在這一包裡找 commit 的位置（以 20 ms 為單位）；找到就先送出到那個位置為止的音訊，再 commit
                var pending = Data()
                var position = chunk.startIndex
                while position < chunk.endIndex {
                    let frameEnd = min(position + frameBytes, chunk.endIndex)
                    let frame = chunk.subdata(in: position..<frameEnd)
                    pending.append(frame)
                    position = frameEnd
                    var reason: String?
                    let turnSeconds = Double(sentBytes + pending.count - lastCommitBytes) / 48_000
                    switch commitMode {
                    case .atEnd:
                        break
                    case .interval(let seconds):
                        if turnSeconds >= seconds { reason = "interval" }
                    case .silence(let ms):
                        if rms(frame) > vadThreshold {
                            speechSinceCommit = true
                            silenceRunMs = 0
                        } else {
                            silenceRunMs += frame.count / 48
                        }
                        if speechSinceCommit, silenceRunMs >= ms { reason = "silence" }
                    case .plan(let positions):
                        // 循環播放時位置不重複使用；只支援播放一次
                        let positionMs = (sentBytes + pending.count) / 48
                        if planIndex < positions.count, positionMs >= positions[planIndex] {
                            reason = "plan"
                            while planIndex < positions.count, positionMs >= positions[planIndex] { planIndex += 1 }
                        }
                    }
                    if reason == nil, maxTurnSeconds > 0, turnSeconds >= maxTurnSeconds { reason = "max-turn" }
                    if let reason {
                        try await append(pending)
                        pending = Data()
                        try await commit(reason)
                    }
                }
                try await append(pending)

                let sentSeconds = Double(sentBytes) / 48_000
                if sentSeconds >= nextProgress {
                    print("  已送出 \(Int(sentSeconds / 60)) 分鐘的音訊，連線 \(recorder.sinceConnectMs / 1000) 秒，commit \(commits) 次，仍在線")
                    fflush(stdout)
                    nextProgress += 300
                }
                if loopMinutes <= 0, offset == 0 { break }
                try await clock.sleep(until: started + .milliseconds(Int(Double(sentBytes) / 48.0 / speed)))
            }
            if sentBytes > lastCommitBytes, !recorder.isDisconnected { try await commit("end") }
        } catch {
            sendError = redact("\(error)")
        }
    }
    let sentSeconds = Double(sentBytes) / 48_000
    let streamedFor = clock.now - started

    // 等每一段都有結果
    let settled = try await waitUntil(finalWait) { recorder.settledItems >= commits || recorder.isDisconnected }
    let finalTook = clock.now - (started + streamedFor)

    var holdReport: [String: Any] = [:]
    if holdMinutes > 0, !recorder.isDisconnected {
        let holdStarted = clock.now
        print("保持連線、不送音訊 \(holdMinutes) 分鐘（連線已經 \(recorder.sinceConnectMs / 1000) 秒）……")
        fflush(stdout)
        var nextReport = 300.0
        while clock.now - holdStarted < .seconds(holdMinutes * 60), !recorder.isDisconnected {
            try await Task.sleep(for: .seconds(1))
            let heldSeconds = Double((clock.now - holdStarted).components.seconds)
            if heldSeconds >= nextReport {
                print("  已閒置 \(Int(heldSeconds / 60)) 分鐘，連線 \(recorder.sinceConnectMs / 1000) 秒，仍在線")
                fflush(stdout)
                nextReport += 300
            }
        }
        holdReport["held_seconds"] = Double((clock.now - holdStarted).components.seconds)
        holdReport["still_connected_after_hold"] = !recorder.isDisconnected
        holdReport["since_connect_ms_after_hold"] = recorder.sinceConnectMs
    }

    socket.cancel(with: .normalClosure, reason: nil)
    receiver.cancel()

    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    var summary = recorder.snapshot()
    summary["config"] = [
        "audio": noAudio ? "" : arguments.positional[1], "session": session, "chunk_ms": chunkMs, "speed": speed,
        "loop_minutes": loopMinutes, "commit": arguments.string("commit", default: "none"), "max_turn_seconds": maxTurnSeconds,
        "vad_threshold": vadThreshold, "url_query": query,
    ]
    summary["connect_to_session_created_ms"] = createdMs
    summary["session_update_to_response_ms"] = updatedMs
    summary["session_update_accepted"] = accepted
    summary["audio_sent_seconds"] = (sentSeconds * 1000).rounded() / 1000
    summary["streaming_wall_seconds"] = (seconds(streamedFor) * 1000).rounded() / 1000
    summary["final_wait_seconds"] = (seconds(finalTook) * 1000).rounded() / 1000
    summary["all_items_settled"] = settled
    summary["client_commits"] = commits
    summary["send_error"] = sendError as Any
    summary["hold"] = holdReport
    summary["upstream_audio_bytes_base64"] = sentBytes * 4 / 3
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: outDirectory.appendingPathComponent("summary.json"))
    try (summary["delta_text"] as? String ?? "").write(
        to: outDirectory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    try (summary["final_text"] as? String ?? "").write(
        to: outDirectory.appendingPathComponent("final.txt"), atomically: true, encoding: .utf8)

    // 精簡報告
    let counts = summary["event_counts"] as? [String: Int] ?? [:]
    print("連線到 session.created \(createdMs) ms；送出設定到回應 \(updatedMs) ms；設定\(accepted ? "已生效" : "沒有生效")")
    print("送出音訊 \(String(format: "%.1f", sentSeconds)) 秒（實際花 \(String(format: "%.1f", seconds(streamedFor))) 秒，\(chunkMs) ms 一包），commit \(commits) 次，最後一段等了 \(String(format: "%.1f", seconds(finalTook))) 秒\(settled ? "" : "（逾時）")")
    print("事件數：" + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
    print("第一段文字：\(summary["first_delta_ms"] as? Int ?? -1) ms；回報的計費秒數：\(summary["usage_seconds"] as? Double ?? 0)；下行 \((summary["downstream_bytes"] as? Int ?? 0) / 1024) KB")
    if let disconnect = summary["disconnect"] as? [String: Any] { print("連線中斷：\(disconnect)") }
    if !holdReport.isEmpty { print("閒置測試：\(holdReport)") }
    if let sendError { print("傳送錯誤：\(sendError)") }
    for error in summary["errors"] as? [String] ?? [] { print("錯誤事件：\(error.prefix(600))") }
    print("增量文字：\((summary["delta_text"] as? String ?? "").prefix(200))")
    print("完成文字：\((summary["final_text"] as? String ?? "").prefix(200))")
}
