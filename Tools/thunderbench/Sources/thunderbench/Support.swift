import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// 任何要印出或存檔的伺服器文字都先經過這裡，確保 API Key 不會出現在輸出裡。
func redact(_ text: String) -> String {
    text.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{6,}"#, with: "sk-[redacted]", options: .regularExpression)
}

/// API Key 只從環境變數讀取（由呼叫端從 Keychain 取出後傳入），永遠不印出。
func apiKey() -> String {
    guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else { fail("沒有設定 OPENAI_API_KEY") }
    return key
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(item)
            }
            index += 1
        }
    }

    func string(_ name: String, default value: String) -> String { options[name] ?? value }
    func double(_ name: String, default value: Double) -> Double { options[name].flatMap(Double.init) ?? value }
    func int(_ name: String, default value: Int) -> Int { options[name].flatMap(Int.init) ?? value }
}

// MARK: WAV（16-bit PCM、單聲道）

struct WavAudio {
    var sampleRate: Int
    var samples: [Int16]

    var duration: Double { Double(samples.count) / Double(sampleRate) }

    static func read(_ url: URL) throws -> WavAudio {
        let data = try Data(contentsOf: url)
        guard data.count > 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
            String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
        else { fail("\(url.lastPathComponent) 不是 WAV 檔") }
        func u32(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24 }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        var offset = 12
        var sampleRate = 0, channels = 0, bits = 0, format = 0
        var pcm = Data()
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); sampleRate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                pcm = data.subdata(in: body..<min(body + size, data.count))
            }
            offset = body + size + (size % 2)
        }
        guard format == 1, channels == 1, bits == 16 else {
            fail("\(url.lastPathComponent) 必須是 16-bit PCM 單聲道（目前 format=\(format) channels=\(channels) bits=\(bits)）。可用：afconvert -f WAVE -d LEI16@24000 -c 1 in out.wav")
        }
        let samples = pcm.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        return WavAudio(sampleRate: sampleRate, samples: samples)
    }

    func write(_ url: URL) throws {
        var data = Data()
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + byteCount); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(byteCount)
        samples.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    var pcmData: Data {
        samples.withUnsafeBufferPointer { buffer in buffer.withMemoryRebound(to: UInt8.self) { Data($0) } }
    }
}

func jsonLine(_ object: Any) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}
