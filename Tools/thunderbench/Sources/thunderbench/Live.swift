import Foundation
import ThunderCore
import ThunderEngines

/// 用正式的引擎以即時速度處理一個音檔，印出每個字幕事件。會產生 API 費用。
///
/// 用來在接上麥克風與畫面之前，確認整個引擎（轉錄連線、停頓偵測、切段、翻譯）對真正的服務是通的。
func live(_ arguments: Arguments) async throws {
    guard arguments.positional.count >= 2 else { fail("用法：thunderbench live <音檔.wav> [--seconds N]") }
    let audio = try WavAudio.read(URL(fileURLWithPath: arguments.positional[1]))
    guard audio.sampleRate == 24_000 else { fail("音檔必須是 24 kHz（目前 \(audio.sampleRate)）") }
    let seconds = min(arguments.double("seconds", default: audio.duration), audio.duration)
    let quiet = arguments.flags.contains("quiet")

    var configuration = TranscribeTranslateEngine.Configuration()
    configuration.link.settings.delay = arguments.string("delay", default: "low")
    configuration.translation.provisional = !arguments.flags.contains("no-provisional")
    if let path = arguments.options["keywords"] {
        let keywords = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        configuration.link.settings.keywords = keywords
        configuration.translation.keywords = keywords
    }
    if let title = arguments.options["title"] {
        configuration.translation.title = title
        configuration.link.settings.prompt = "Talk title: \(title)"
    }
    let key = apiKey()
    let engine = TranscribeTranslateEngine(configuration: configuration, apiKey: key, textModel: OpenAITextModel(apiKey: key))

    let (stream, input) = AsyncStream<AudioChunk>.makeStream()
    let clock = ContinuousClock()
    let started = clock.now
    func elapsed() -> Double {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    // 以即時速度送出：每 200 ms 一包
    let pcm = audio.pcmData
    let feeder = Task {
        let chunkBytes = 9_600
        var offset = 0
        var index = 0
        while offset < pcm.count, Double(index) * 0.2 < seconds {
            let end = min(offset + chunkBytes, pcm.count)
            input.yield(AudioChunk(pcm16: pcm.subdata(in: offset..<end), sampleRate: 24_000, startTime: AudioTime(seconds: Double(index) * 0.2)))
            offset = end
            index += 1
            let due = Double(index) * 0.2
            let wait = due - elapsed()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        input.finish()
    }

    var segmentEndedAt: [Int: Double] = [:]
    var segmentStartedAt: [Int: Double] = [:]
    var finalDelays: [Double] = []
    var firstChineseDelays: [Double] = []
    var seenChinese: Set<Int> = []
    var english: [Int: String] = [:]
    var chinese: [Int: String] = [:]
    var provisionalCount = 0
    var billed = 0.0
    var line = ""

    func stamp() -> String { String(format: "[%6.2f]", elapsed()) }
    func flushLine() {
        if !line.isEmpty, !quiet { print("\(stamp()) EN … \(line.trimmingCharacters(in: .whitespaces))") }
        line = ""
    }

    for await event in engine.run(audio: stream, config: EngineConfig()) {
        switch event {
        case .status(let status):
            flushLine()
            print("\(stamp()) 狀態 \(status)")
        case .source(let text):
            guard let segment = text.segment else { continue }
            if text.kind == .delta {
                if segmentStartedAt[segment] == nil { segmentStartedAt[segment] = elapsed() }
                line += text.text
            } else {
                line = ""
                if segmentEndedAt[segment] == nil { segmentEndedAt[segment] = elapsed() }
                english[segment] = text.text
                print("\(stamp()) EN ■ \(segment)：\(text.text)")
            }
        case .provisional(let text):
            guard let segment = text.segment else { continue }
            provisionalCount += 1
            if seenChinese.insert(segment).inserted, let begin = segmentStartedAt[segment] {
                firstChineseDelays.append(elapsed() - begin)
            }
            if !quiet { print("\(stamp()) 中 ~ \(segment)：\(text.text)") }
        case .translation(let text):
            guard let segment = text.segment else { continue }
            if chinese[segment] == nil, let ended = segmentEndedAt[segment] { finalDelays.append(elapsed() - ended) }
            if seenChinese.insert(segment).inserted, let begin = segmentStartedAt[segment] {
                firstChineseDelays.append(elapsed() - begin)
            }
            chinese[segment] = text.text
            print("\(stamp()) 中 ■ \(segment)：\(text.text)")
        case .gap(let gap):
            print("\(stamp()) 缺口 \(gap.from.seconds)–\(gap.to.seconds) \(gap.reason)")
        case .usage(let seconds):
            billed = seconds
        }
    }
    feeder.cancel()

    func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    func p95(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))]
    }
    let simplified = chinese.values.filter { ChineseScript.containsSimplified($0) }.count
    print("")
    print(String(format: "音訊 %.1f 秒，計費 %.1f 秒（約 US$%.4f）", seconds, billed, billed / 60 * 0.017))
    print("段數 \(english.count)，有中文定稿 \(chinese.count)，暫定譯文更新 \(provisionalCount) 次，含簡體字的定稿 \(simplified)")
    print(String(format: "中文定稿：英文確定之後 中位數 %.2f 秒、P95 %.2f 秒", median(finalDelays), p95(finalDelays)))
    print(String(format: "第一個中文字：這一段第一個英文字出現之後 中位數 %.2f 秒、P95 %.2f 秒", median(firstChineseDelays), p95(firstChineseDelays)))
}
