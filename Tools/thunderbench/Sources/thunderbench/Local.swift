import AVFoundation
import CoreMedia
import Foundation
import Speech

/// thunderbench local：用 macOS 內建的本機語音辨識（SpeechAnalyzer＋SpeechTranscriber，macOS 26 起）處理音檔。
///
/// 以即時速度（或 `--speed` 倍速；0 是能多快就多快）一次送 0.1 秒的音訊，記下每個結果（暫時的與確定的）
/// 出現的時間與涵蓋的音訊範圍，給分析腳本和 OpenAI（`thunderbench live`）的結果比較。
/// 不連網路、不花費用；第一次使用某個語系時，系統會下載辨識模型。
func local(_ arguments: Arguments) async throws {
    guard arguments.positional.count >= 2 else {
        fail("用法：thunderbench local <音檔.wav> [--events <事件.jsonl>] [--module speech|dictation] [--speed 1] [--fast] [--keywords <一行一個的檔案>] [--seconds N] [--locale en-US]")
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments.positional[1]))
    let fileRate = file.processingFormat.sampleRate
    let speed = arguments.double("speed", default: 1)
    let seconds = min(arguments.double("seconds", default: Double(file.length) / fileRate), Double(file.length) / fileRate)
    let locale = Locale(identifier: arguments.string("locale", default: "en-US"))

    // --module speech（SpeechTranscriber，長篇轉錄用的新模型）或 dictation（DictationTranscriber，聽寫用的模型）。
    // --fast：speech 要求更快的暫時結果（fastResults）；dictation 更常確定（frequentFinalization）。
    let fast = arguments.flags.contains("fast")
    let transcriber: any SpeechModule
    let speech: SpeechTranscriber?
    let dictation: DictationTranscriber?
    switch arguments.string("module", default: "speech") {
    case "speech":
        guard SpeechTranscriber.isAvailable else { fail("這台電腦不能使用 SpeechTranscriber") }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.fastResults) }
        speech = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [.audioTimeRange])
        dictation = nil
        transcriber = speech!
    case "dictation":
        var reporting: Set<DictationTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.frequentFinalization) }
        dictation = DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: reporting, attributeOptions: [.audioTimeRange])
        speech = nil
        transcriber = dictation!
    default:
        fail("--module 只接受 speech 或 dictation")
    }
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("下載 \(locale.identifier) 的辨識模型…")
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if let path = arguments.options["keywords"] {
        let words = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try await analyzer.setContext(context)
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fail("找不到辨識模型能用的音訊格式")
    }
    try await analyzer.prepareToAnalyze(in: format)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        fail("無法把 \(file.processingFormat) 轉成 \(format)")
    }

    // --events：每個結果寫成一行 JSON（經過的秒數、暫時或確定、涵蓋的音訊範圍、文字）
    let events: FileHandle? = arguments.options["events"].map { path in
        guard FileManager.default.createFile(atPath: path, contents: nil), let handle = FileHandle(forWritingAtPath: path) else {
            fail("無法寫入 \(path)")
        }
        return handle
    }
    let clock = ContinuousClock()
    let start = clock.now
    func elapsed() -> Double {
        let duration = clock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
    func record(_ object: [String: Any]) {
        guard let events, var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        events.write(data)
    }

    // 兩種模型的結果型別不同，但都有涵蓋的範圍、是否確定與文字
    func collect<Results: AsyncSequence>(_ results: Results, text: @escaping (Results.Element) -> String) async throws
        -> (volatile: Int, final: Int, first: Double?) where Results.Element: SpeechModuleResult
    {
        var volatile = 0
        var finals = 0
        var first: Double?
        for try await result in results {
            let t = elapsed()
            if first == nil { first = t }
            if result.isFinal { finals += 1 } else { volatile += 1 }
            record([
                "t": (t * 1_000).rounded() / 1_000, "kind": result.isFinal ? "final" : "volatile",
                "start": result.range.start.seconds, "end": result.range.end.seconds, "text": text(result),
            ])
        }
        return (volatile, finals, first)
    }
    let reader = Task { () -> (volatile: Int, final: Int, first: Double?) in
        if let speech { return try await collect(speech.results) { String($0.text.characters) } }
        return try await collect(dictation!.results) { String($0.text.characters) }
    }

    let cpuBefore = processCPUSeconds()
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: stream)
    let chunkFrames = AVAudioFrameCount(fileRate * 0.1)
    let totalFrames = AVAudioFramePosition(seconds * fileRate)
    let ratio = format.sampleRate / fileRate
    var readFrames: AVAudioFramePosition = 0
    var sentFrames: Int64 = 0
    while readFrames < totalFrames {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), totalFrames - readFrames))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(count) * ratio) + 256)
        else { fail("無法配置音訊緩衝區") }
        try file.read(into: chunk, frameCount: count)
        readFrames += AVAudioFramePosition(chunk.frameLength)
        let last = readFrames >= totalFrames || chunk.frameLength == 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = last ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return chunk
        }
        if status == .error { fail("音訊轉換失敗：\(error?.localizedDescription ?? "")") }
        if converted.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: converted, bufferStartTime: CMTime(value: sentFrames, timescale: CMTimeScale(format.sampleRate))))
            sentFrames += Int64(converted.frameLength)
        }
        if chunk.frameLength == 0 { break }
        if speed > 0 { try await clock.sleep(until: start.advanced(by: .seconds(Double(readFrames) / fileRate / speed))) }
    }
    let sentAt = elapsed()
    input.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let counts = try await reader.value
    let wall = elapsed()
    let cpu = processCPUSeconds() - cpuBefore
    record(["t": (wall * 1_000).rounded() / 1_000, "kind": "end", "sent_at": sentAt])
    print(
        String(
            format: "音訊 %.1f 秒（%@，%.0f Hz）；經過 %.1f 秒；送完之後 %.2f 秒收完；第一個結果 %.2f 秒；暫時 %d 個、確定 %d 個；這個程序的 CPU %.1f 秒（%.1f%%）",
            seconds, speed > 0 ? "\(speed) 倍速" : "不等待", format.sampleRate, wall, wall - sentAt, counts.first ?? -1, counts.volatile,
            counts.final, cpu, cpu / wall * 100))
}

/// 這個程序到目前為止用掉的 CPU 時間（使用者＋系統，秒）。辨識模型如果在系統的其他程序裡跑，不算在這裡。
private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec)
        + Double(usage.ru_stime.tv_usec) / 1e6
}
