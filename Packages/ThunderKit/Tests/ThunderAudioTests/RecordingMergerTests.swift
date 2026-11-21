import AVFoundation
import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

/// 一個分段：取樣率、長度，以及裡面那個正弦波的頻率（振幅 0.5）。
private struct Part {
    var rate: Double
    var seconds: Double
    var frequency: Double
}

/// 把每個部分各寫成一個 CAF 分段。
private func record(_ parts: [Part], in directory: URL) throws -> [RecordingSegment] {
    guard let first = parts.first else { return [] }
    let recorder = try SegmentedRecorder(directory: directory, sampleRate: first.rate, segmentDuration: 3_600)
    for (index, part) in parts.enumerated() {
        if index > 0 { try recorder.beginNewSegment(sampleRate: part.rate) }
        try Signal.sine(frequency: part.frequency, sampleRate: part.rate, duration: part.seconds)
            .withUnsafeBufferPointer { try recorder.append($0) }
    }
    try recorder.close()
    return try RecordingFiles.segments(in: directory)
}

/// 把音訊檔解碼成樣本。
private func decode(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let sampleRate = file.processingFormat.sampleRate
    guard file.length > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { return ([], sampleRate) }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return ([], sampleRate) }
    return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), sampleRate)
}

/// `samples` 裡第 `from` 秒到第 `to` 秒的音量（方均根）與每秒過零的次數（頻率 f 的正弦波約 2f 次）。
private func measure(_ samples: [Float], sampleRate: Double, from: Double, to: Double) -> (rms: Double, crossings: Double) {
    let range = min(Int(from * sampleRate), samples.count)..<min(Int(to * sampleRate), samples.count)
    guard range.count > 1 else { return (0, 0) }
    var energy = 0.0
    var crossings = 0
    var lastSign = 0
    for sample in samples[range] {
        energy += Double(sample) * Double(sample)
        let sign = sample > 0 ? 1 : sample < 0 ? -1 : 0
        if sign != 0 {
            if lastSign != 0 && sign != lastSign { crossings += 1 }
            lastSign = sign
        }
    }
    return ((energy / Double(range.count)).squareRoot(), Double(crossings) / (Double(range.count) / sampleRate))
}

/// 振幅 0.5 的正弦波的方均根。
private let sineLevel = 0.5 / 2.0.squareRoot()

@Suite("RecordingMerger：把 CAF 分段合併成 recording.m4a")
struct RecordingMergerTests {
    @Test("合併後的時長等於各分段的總和，聲音還在（不是靜音，頻率與音量不變）")
    func mergesSegmentsInOrder() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let segments = try record(
            [Part(rate: 16_000, seconds: 1, frequency: 440), Part(rate: 16_000, seconds: 1, frequency: 440),
             Part(rate: 16_000, seconds: 0.7, frequency: 440)],
            in: tmp.url.appendingPathComponent("audio"))
        #expect(segments.count == 3)

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(abs(duration - 2.7) < 0.01)
        #expect(abs(duration - RecordingFiles.totalDuration(of: segments)) < 0.01)
        #expect(abs(try RecordingMerger.duration(of: output) - duration) < 1e-9)
        let decoded = try decode(output)
        #expect(decoded.sampleRate == 16_000)
        #expect(abs(Double(decoded.samples.count) / 16_000 - 2.7) < 0.01)
        let sound = measure(decoded.samples, sampleRate: 16_000, from: 0.1, to: 2.6)
        #expect(abs(sound.rms - sineLevel) < 0.05, "音量（方均根）是 \(sound.rms)")
        #expect(abs(sound.crossings - 880) < 30, "每秒過零 \(sound.crossings) 次")
    }

    @Test("分段的取樣率不同：轉成第一個分段的取樣率，時長與音高都不變")
    func mixedSampleRates() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let segments = try record(
            [Part(rate: 16_000, seconds: 1, frequency: 440), Part(rate: 48_000, seconds: 1, frequency: 880),
             Part(rate: 8_000, seconds: 1, frequency: 220)],
            in: tmp.url.appendingPathComponent("audio"))
        #expect(segments.map(\.sampleRate) == [16_000, 48_000, 8_000])

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(abs(duration - 3) < 0.01)
        let decoded = try decode(output)
        #expect(decoded.sampleRate == 16_000)
        // 每一秒各自量（避開接縫前後 0.1 秒）。沒有轉換取樣率就直接接的話，後兩段的音高會跑掉
        for (second, frequency) in [(0.0, 440.0), (1.0, 880.0), (2.0, 220.0)] {
            let sound = measure(decoded.samples, sampleRate: 16_000, from: second + 0.1, to: second + 0.9)
            #expect(abs(sound.crossings - 2 * frequency) < 0.05 * 2 * frequency, "第 \(Int(second)) 秒每秒過零 \(sound.crossings) 次")
            #expect(abs(sound.rms - sineLevel) < 0.06, "第 \(Int(second)) 秒的音量是 \(sound.rms)")
        }
    }

    @Test(
        "各種取樣率都能合併（取樣率低時編碼器不接受 64 kbps，改用它接受的最高位元率）",
        arguments: [8_000.0, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000])
    func supportedSampleRates(rate: Double) throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let segments = try record(
            [Part(rate: rate, seconds: 1, frequency: 440)], in: tmp.url.appendingPathComponent("audio"))

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(abs(duration - 1) < 0.01)
        let decoded = try decode(output)
        #expect(decoded.sampleRate == rate)
        let sound = measure(decoded.samples, sampleRate: rate, from: 0.1, to: 0.9)
        #expect(abs(sound.rms - sineLevel) < 0.06, "音量（方均根）是 \(sound.rms)")
        #expect(abs(sound.crossings - 880) < 44, "每秒過零 \(sound.crossings) 次")
    }

    @Test("AAC 不支援的取樣率（96 kHz）：改用 48 kHz，時長與音高不變")
    func unsupportedSampleRate() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let segments = try record(
            [Part(rate: 96_000, seconds: 1, frequency: 440)], in: tmp.url.appendingPathComponent("audio"))

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(abs(duration - 1) < 0.01)
        let decoded = try decode(output)
        #expect(decoded.sampleRate == 48_000)
        let sound = measure(decoded.samples, sampleRate: 48_000, from: 0.1, to: 0.9)
        #expect(abs(sound.crossings - 880) < 44, "每秒過零 \(sound.crossings) 次")
    }

    @Test("寫到暫存檔再改名：目的地原有的檔案整個換掉，不留暫存檔（包含上次中斷留下的），來源分段原封不動")
    func replacesTheDestinationAtomically() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let audio = tmp.url.appendingPathComponent("audio")
        let segments = try record([Part(rate: 16_000, seconds: 1, frequency: 440)], in: audio)
        try Data("不是音訊".utf8).write(to: output)
        // 上次合併到一半被強制結束留下的暫存檔
        let leftover = tmp.url.appendingPathComponent(".recording.m4a.\(UUID().uuidString).tmp.m4a")
        try Data("寫到一半".utf8).write(to: leftover)

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(abs(duration - 1) < 0.01)
        #expect(abs(try RecordingMerger.duration(of: output) - 1) < 0.01)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).sorted() == ["audio", "recording.m4a"])
        #expect(try RecordingFiles.segments(in: audio) == segments)
    }

    @Test("沒有分段可以合併時丟出錯誤，不建立檔案")
    func nothingToMerge() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")

        #expect(throws: RecordingMergerError.noAudio) {
            try RecordingMerger.merge(segments: [], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty)
    }

    @Test("分段檔比檔頭宣稱的短（被截斷）：合併讀得到的部分，回傳的時長比分段的總長短，呼叫端看得出不完整")
    func truncatedSegment() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let output = tmp.url.appendingPathComponent("recording.m4a")
        let segments = try record(
            [Part(rate: 16_000, seconds: 2, frequency: 440), Part(rate: 16_000, seconds: 2, frequency: 440)],
            in: tmp.url.appendingPathComponent("audio"))
        let damaged = try #require(segments.last)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: damaged.url.path)[.size] as? NSNumber)
        #expect(truncate(damaged.url.path, off_t(size.intValue / 2)) == 0)
        // 檔頭還是寫著 2 秒
        let claimed = RecordingFiles.totalDuration(of: try RecordingFiles.segments(in: tmp.url.appendingPathComponent("audio")))
        #expect(abs(claimed - 4) < 0.01)

        let duration = try RecordingMerger.merge(segments: segments, to: output)

        #expect(duration > 2.5 && duration < 3.5, "合併出 \(duration) 秒")
        #expect(claimed - duration > 0.2)
        #expect(abs(try RecordingMerger.duration(of: output) - duration) < 1e-9)
    }
}
