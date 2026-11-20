import Foundation

/// 記錄收到的每一個事件與時間。接收與傳送在不同的 task，所以用鎖保護。
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let clock = ContinuousClock()
    private let connectedAt: ContinuousClock.Instant
    private var audioStartedAt: ContinuousClock.Instant?
    private var sentMs = 0

    private(set) var counts: [String: Int] = [:]
    private(set) var sourceText = ""
    private(set) var translatedText = ""
    private(set) var firstSourceMs: Int?
    private(set) var firstTranslationMs: Int?
    private(set) var downstreamAudioBytes = 0
    private(set) var downstreamTextBytes = 0
    private(set) var errors: [String] = []
    private(set) var sessionCreated: [String: Any]?
    private(set) var sessionUpdated: [String: Any]?
    private(set) var sawClosed = false
    private(set) var disconnect: [String: Any]?
    private(set) var lastEventMs = 0

    init(file: FileHandle) {
        self.file = file
        self.connectedAt = clock.now
    }

    private func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let elapsed = clock.now - instant
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 從開始送音訊算起的毫秒數；還沒開始送音訊時是負的（以連線時間為準）。
    private func now() -> Int {
        if let audioStartedAt { return milliseconds(since: audioStartedAt) }
        return milliseconds(since: connectedAt) - 1_000_000_000
    }

    func markAudioStart() { lock.withLock { audioStartedAt = clock.now } }
    func setSent(milliseconds: Int) { lock.withLock { sentMs = milliseconds } }
    var isDisconnected: Bool { lock.withLock { disconnect != nil || sawClosed } }
    var closed: Bool { lock.withLock { sawClosed } }
    var sinceConnectMs: Int { milliseconds(since: connectedAt) }

    func record(_ raw: String) {
        lock.withLock {
            let rx = audioStartedAt == nil ? nil : now() as Int?
            guard var event = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                file.write(jsonLine(["rx_ms": rx as Any, "sent_ms": sentMs, "unparsed": redact(String(raw.prefix(500)))]))
                return
            }
            let type = event["type"] as? String ?? "?"
            counts[type, default: 0] += 1
            switch type {
            case "session.output_audio.delta":
                // 語音內容不存，只記大小（用來估算頻寬）
                let base64 = event["delta"] as? String ?? ""
                let bytes = base64.count * 3 / 4
                downstreamAudioBytes += bytes
                event["delta"] = nil
                event["audio_bytes"] = bytes
            case "session.input_transcript.delta":
                let delta = event["delta"] as? String ?? ""
                sourceText += delta
                downstreamTextBytes += raw.utf8.count
                if firstSourceMs == nil, let rx { firstSourceMs = rx }
            case "session.output_transcript.delta":
                let delta = event["delta"] as? String ?? ""
                translatedText += delta
                downstreamTextBytes += raw.utf8.count
                if firstTranslationMs == nil, let rx { firstTranslationMs = rx }
            case "session.created":
                sessionCreated = event
            case "session.updated":
                sessionUpdated = event
            case "session.closed":
                sawClosed = true
            case "error":
                errors.append(redact(raw))
            default:
                break
            }
            if let rx { lastEventMs = rx }
            var line: [String: Any] = ["sent_ms": sentMs, "since_connect_ms": milliseconds(since: connectedAt), "event": event]
            if let rx { line["rx_ms"] = rx }
            file.write(jsonLine(line))
        }
    }

    func noteDisconnect(error: String, closeCode: Int, reason: String?) {
        lock.withLock {
            guard disconnect == nil, !sawClosed else { return }
            disconnect = [
                "error": redact(error), "close_code": closeCode, "reason": reason ?? "",
                "since_connect_ms": milliseconds(since: connectedAt), "sent_ms": sentMs,
            ]
        }
    }

    func snapshot() -> [String: Any] {
        lock.withLock {
            [
                "event_counts": counts, "first_source_delta_ms": firstSourceMs as Any,
                "first_translation_delta_ms": firstTranslationMs as Any, "downstream_audio_bytes": downstreamAudioBytes,
                "downstream_text_bytes": downstreamTextBytes, "errors": errors, "saw_session_closed": sawClosed,
                "disconnect": disconnect as Any, "source_text": sourceText, "translated_text": translatedText,
                "session_created": sessionCreated as Any, "session_updated": sessionUpdated as Any,
                "last_event_rx_ms": lastEventMs,
            ]
        }
    }
}

/// 把音檔串流到 gpt-realtime-translate，錄下所有事件。會產生 API 費用。
func translate(_ arguments: Arguments) async throws {
    guard arguments.positional.count >= 2, let outPath = arguments.options["out"] else {
        fail("用法：thunderbench translate <音檔.wav> --out <資料夾> [選項]")
    }
    let audio = try WavAudio.read(URL(fileURLWithPath: arguments.positional[1]))
    guard audio.sampleRate == 24_000 else { fail("音檔必須是 24 kHz（目前 \(audio.sampleRate)）") }

    let language = arguments.string("language", default: "zh")
    let model = arguments.string("model", default: "gpt-realtime-translate")
    let sourceModel = arguments.string("source-model", default: "gpt-realtime-whisper")
    let chunkMs = arguments.int("chunk-ms", default: 200)
    let speed = arguments.double("speed", default: 1)
    let wantSource = !arguments.flags.contains("no-source")
    let noise = arguments.string("noise-reduction", default: "none")
    let loopMinutes = arguments.double("loop-minutes", default: 0)
    let preconnectSeconds = arguments.double("preconnect-seconds", default: 0)
    let closeWait = arguments.double("close-wait", default: 20)
    let skipUpdate = arguments.flags.contains("skip-session-update")

    let outDirectory = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    let eventsURL = outDirectory.appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    let recorder = EventRecorder(file: try FileHandle(forWritingTo: eventsURL))

    var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(model)")!)
    request.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.maximumMessageSize = 32 << 20
    let connectStarted = ContinuousClock.now
    socket.resume()

    let receiver = Task {
        while true {
            do {
                switch try await socket.receive() {
                case .string(let text): recorder.record(text)
                case .data(let data): recorder.record(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                if recorder.closed { break }
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

    // 設定：目標語言、來源語言逐字稿、降噪
    var input: [String: Any] = [:]
    input["transcription"] = wantSource ? ["model": sourceModel] : NSNull()
    input["noise_reduction"] = noise == "none" ? NSNull() : ["type": noise]
    var sendError: String?
    if !skipUpdate {
        do {
            try await send(["type": "session.update", "session": ["audio": ["input": input, "output": ["language": language]]]])
        } catch {
            sendError = redact("session.update 送不出去：\(error)")
        }
        // 給伺服器一點時間回應（例如 API Key 無效時會先送一個 error 事件再關閉連線）
        try await Task.sleep(for: .milliseconds(400))
    }

    if preconnectSeconds > 0 {
        print("先連線、不送音訊 \(preconnectSeconds) 秒……")
        try await Task.sleep(for: .seconds(preconnectSeconds))
        if recorder.isDisconnected { print("  連線在等待期間就中斷了") }
    }

    // 以即時速度（或 --speed 倍速）送出音訊
    let pcm = audio.pcmData
    let bytesPerChunk = 24_000 * 2 * chunkMs / 1000
    let targetSeconds = loopMinutes > 0 ? loopMinutes * 60 : audio.duration
    let clock = ContinuousClock()
    var offset = 0
    var sentBytes = 0
    var chunkIndex = 0
    var nextProgress = 300.0
    recorder.markAudioStart()
    let started = clock.now
    let connectMs = Int((started - connectStarted).components.seconds) * 1000
        + Int((started - connectStarted).components.attoseconds / 1_000_000_000_000_000)

    while sendError == nil, Double(sentBytes) / 48_000 < targetSeconds - 0.0005, !recorder.isDisconnected {
        let end = min(offset + bytesPerChunk, pcm.count)
        let chunk = pcm.subdata(in: offset..<end)
        offset = end >= pcm.count ? 0 : end
        do {
            try await send(["type": "session.input_audio_buffer.append", "audio": chunk.base64EncodedString()])
        } catch {
            sendError = redact("\(error)")
            break
        }
        sentBytes += chunk.count
        chunkIndex += 1
        recorder.setSent(milliseconds: sentBytes / 48)
        let sentSeconds = Double(sentBytes) / 48_000
        if sentSeconds >= nextProgress {
            print("  已送出 \(Int(sentSeconds / 60)) 分鐘的音訊，連線 \(recorder.sinceConnectMs / 1000) 秒，仍在線")
            fflush(stdout)
            nextProgress += 300
        }
        if loopMinutes <= 0, offset == 0 { break }
        try await clock.sleep(until: started + .milliseconds(Int(Double(chunkIndex * chunkMs) / speed)))
    }
    let sentSeconds = Double(sentBytes) / 48_000
    let streamedFor = clock.now - started

    // 正常收尾：送 session.close，等 session.closed
    var closedCleanly = false
    if !recorder.isDisconnected {
        try? await send(["type": "session.close"])
        let deadline = clock.now + .seconds(closeWait)
        while clock.now < deadline, !recorder.isDisconnected { try await Task.sleep(for: .milliseconds(50)) }
        closedCleanly = recorder.closed
    }
    let closeTook = clock.now - (started + streamedFor)
    socket.cancel(with: .normalClosure, reason: nil)
    receiver.cancel()

    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    var summary = recorder.snapshot()
    summary["config"] = [
        "audio": arguments.positional[1], "language": language, "model": model, "source_model": wantSource ? sourceModel : "",
        "chunk_ms": chunkMs, "speed": speed, "noise_reduction": noise, "loop_minutes": loopMinutes,
        "preconnect_seconds": preconnectSeconds,
    ]
    summary["connect_to_first_audio_ms"] = connectMs
    summary["audio_sent_seconds"] = (sentSeconds * 1000).rounded() / 1000
    summary["streaming_wall_seconds"] = (seconds(streamedFor) * 1000).rounded() / 1000
    summary["close_wait_seconds"] = (seconds(closeTook) * 1000).rounded() / 1000
    summary["closed_cleanly"] = closedCleanly
    summary["send_error"] = sendError as Any
    summary["upstream_audio_bytes_base64"] = sentBytes * 4 / 3
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: outDirectory.appendingPathComponent("summary.json"))
    try (summary["source_text"] as? String ?? "").write(
        to: outDirectory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    try (summary["translated_text"] as? String ?? "").write(
        to: outDirectory.appendingPathComponent("translation.txt"), atomically: true, encoding: .utf8)

    // 精簡報告
    let counts = summary["event_counts"] as? [String: Int] ?? [:]
    print("送出音訊 \(String(format: "%.1f", sentSeconds)) 秒（實際花 \(String(format: "%.1f", seconds(streamedFor))) 秒，\(chunkMs) ms 一包）")
    print("事件數：" + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
    print("第一段英文：\(summary["first_source_delta_ms"] as? Int ?? -1) ms   第一段譯文：\(summary["first_translation_delta_ms"] as? Int ?? -1) ms")
    let down = summary["downstream_audio_bytes"] as? Int ?? 0
    print("下行語音 \(down / 1024) KB（每小時約 \(Int(Double(down) / max(sentSeconds, 1) * 3600 / 1_048_576)) MB）；收尾 \(closedCleanly ? "正常" : "未收到 session.closed")，等了 \(String(format: "%.1f", seconds(closeTook))) 秒")
    if let disconnect = summary["disconnect"] as? [String: Any] { print("連線中斷：\(disconnect)") }
    if let sendError { print("傳送錯誤：\(sendError)") }
    for error in summary["errors"] as? [String] ?? [] { print("錯誤事件：\(error.prefix(400))") }
    print("英文：\((summary["source_text"] as? String ?? "").prefix(160))")
    print("譯文：\((summary["translated_text"] as? String ?? "").prefix(160))")
}
