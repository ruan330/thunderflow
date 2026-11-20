import Foundation

/// 用 macOS 的 say 把稿子（一行一句，# 開頭的行是註解）合成為 24 kHz 單聲道 WAV。
/// 一句一句分別合成再接起來，所以每句的起訖時間都精確已知。
func synthesize(_ arguments: Arguments) throws {
    guard arguments.positional.count >= 2, let out = arguments.options["out"] else {
        fail("用法：thunderbench synth <稿子.txt> --out <輸出名稱> [--voice Samantha] [--rate 175] [--pause-ms 350]")
    }
    let voice = arguments.string("voice", default: "Samantha")
    let rate = arguments.int("rate", default: 175)
    let pauseMs = arguments.int("pause-ms", default: 350)
    let sampleRate = 24_000
    let sentences = try String(contentsOf: URL(fileURLWithPath: arguments.positional[1]), encoding: .utf8)
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard !sentences.isEmpty else { fail("稿子是空的") }

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("thunderbench-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: scratch) }

    var all = [Int16](repeating: 0, count: sampleRate / 2)  // 開頭先留 0.5 秒靜音
    var timeline: [[String: Any]] = []
    for (index, sentence) in sentences.enumerated() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice, "-r", String(rate), "-o", scratch.path, "--file-format=WAVE",
            "--data-format=LEI16@\(sampleRate)", sentence,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fail("say 執行失敗（voice：\(voice)）") }
        let audio = try WavAudio.read(scratch)
        guard audio.sampleRate == sampleRate else { fail("say 輸出的取樣率是 \(audio.sampleRate)") }

        // 只取實際有聲音的範圍，頭尾的靜音不算進這一句
        let threshold = 300
        let first = audio.samples.firstIndex { abs(Int($0)) > threshold } ?? 0
        let last = audio.samples.lastIndex { abs(Int($0)) > threshold } ?? max(audio.samples.count - 1, 0)
        let start = Double(all.count) / Double(sampleRate)
        if first <= last, !audio.samples.isEmpty { all += audio.samples[first...last] }
        let end = Double(all.count) / Double(sampleRate)
        timeline.append([
            "index": index, "text": sentence,
            "start": (start * 1000).rounded() / 1000, "end": (end * 1000).rounded() / 1000,
        ])
        all += [Int16](repeating: 0, count: sampleRate * pauseMs / 1000)
    }
    all += [Int16](repeating: 0, count: sampleRate / 2)

    let wav = WavAudio(sampleRate: sampleRate, samples: all)
    try wav.write(URL(fileURLWithPath: out + ".wav"))
    let meta: [String: Any] = [
        "voice": voice, "rate": rate, "pauseMs": pauseMs, "sampleRate": sampleRate,
        "duration": (wav.duration * 1000).rounded() / 1000, "sentences": timeline,
    ]
    try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: out + ".json"))
    print("已產生 \(out).wav：\(sentences.count) 句、\(String(format: "%.1f", wav.duration)) 秒（voice：\(voice)、每分鐘 \(rate) 字）")
}
