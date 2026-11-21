import Foundation
import Testing
import ThunderAudio
import ThunderTestKit

@Suite("SegmentedRecorder：把錄音寫成一連串 CAF 分段")
struct SegmentedRecorderTests {
    private let rate = 8_000.0

    /// 把 `samples` 以每次 `pieceSize` 個樣本的方式寫入。
    private func append(_ samples: [Float], to recorder: SegmentedRecorder, pieceSize: Int = 777) throws {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + pieceSize, samples.count)
            try samples[offset..<end].withUnsafeBufferPointer { try recorder.append($0) }
            offset = end
        }
    }

    private func largestDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    @Test("寫入的樣本數與內容，讀回來一致（16-bit 量化誤差以內）")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let input = Signal.sine(frequency: 220, sampleRate: rate, duration: 1.5)

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try append(input, to: recorder)
        #expect(recorder.framesWritten == Int64(input.count))
        #expect(abs(recorder.duration - 1.5) < 1e-9)
        try recorder.close()

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.index == 0)
        #expect(segment.url.lastPathComponent == "000.caf")
        #expect(segment.sampleRate == rate)
        #expect(segment.frameCount == Int64(input.count))
        #expect(largestDifference(try RecordingFiles.readSamples(of: segment), input) < 1e-4)
    }

    @Test("每滿一個分段長度就換檔：每段一樣長，最後一段是剩下的，接起來等於原本的聲音")
    func rotatesAtExactBoundaries() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let input = Signal.sine(frequency: 220, sampleRate: rate, duration: 3.5)

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate, segmentDuration: 1)
        try append(input, to: recorder)
        try recorder.close()

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.map(\.frameCount) == [8_000, 8_000, 8_000, 4_000])
        #expect(segments.map(\.index) == [0, 1, 2, 3])
        #expect(segments.map(\.url.lastPathComponent) == ["000.caf", "001.caf", "002.caf", "003.caf"])
        #expect(RecordingFiles.totalFrames(of: segments) == Int64(input.count))
        #expect(abs(RecordingFiles.totalDuration(of: segments) - 3.5) < 1e-9)

        let joined = try segments.flatMap { try RecordingFiles.readSamples(of: $0) }
        #expect(largestDifference(joined, input) < 1e-4)
    }

    @Test("一次寫入的樣本跨過好幾個分段也沒問題")
    func singleAppendSpanningSegments() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let input = Signal.sine(frequency: 220, sampleRate: rate, duration: 2.25)

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate, segmentDuration: 0.5)
        try append(input, to: recorder, pieceSize: input.count)
        try recorder.close()

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.map(\.frameCount) == [4_000, 4_000, 4_000, 4_000, 2_000])
        let joined = try segments.flatMap { try RecordingFiles.readSamples(of: $0) }
        #expect(largestDifference(joined, input) < 1e-4)
    }

    @Test("不必等關檔：每次 append 之後，別人就能從檔案讀到完整的資料")
    func dataIsReadableWithoutClosing() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let input = Signal.sine(frequency: 220, sampleRate: rate, duration: 1)

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try append(input, to: recorder)

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.map(\.frameCount) == [8_000])
        if let segment = segments.first {
            #expect(largestDifference(try RecordingFiles.readSamples(of: segment), input) < 1e-4)
        }
        try recorder.close()
    }

    @Test("超出 ±1.0 的樣本會被限幅，不會繞回成反向的值")
    func clipsOutOfRangeSamples() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let input: [Float] = [1.5, -1.5, 2, -3, 0.5, -0.5, 1, -1]

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try append(input, to: recorder)
        try recorder.close()

        let segment = try #require(try RecordingFiles.segments(in: tmp.url).first)
        let output = try RecordingFiles.readSamples(of: segment)
        #expect(output.count == input.count)
        guard output.count == input.count else { return }
        for index in [0, 2, 6] { #expect(output[index] > 0.999, "第 \(index) 個樣本應該被限制在 +1") }
        for index in [1, 3, 7] { #expect(output[index] < -0.999, "第 \(index) 個樣本應該被限制在 -1") }
        #expect(abs(output[4] - 0.5) < 1e-4)
        #expect(abs(output[5] + 0.5) < 1e-4)
    }

    @Test("取樣率改變時開新分段，總長度照各段自己的取樣率計算")
    func sampleRateChangeStartsNewSegment() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: 8_000)
        try append(Signal.sine(frequency: 220, sampleRate: 8_000, duration: 1), to: recorder)
        try recorder.beginNewSegment(sampleRate: 16_000)
        try append(Signal.sine(frequency: 220, sampleRate: 16_000, duration: 1), to: recorder)
        #expect(recorder.framesWritten == 24_000)
        #expect(abs(recorder.duration - 2) < 1e-9)
        try recorder.close()

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.map(\.sampleRate) == [8_000, 16_000])
        #expect(segments.map(\.frameCount) == [8_000, 16_000])
        #expect(abs(RecordingFiles.totalDuration(of: segments) - 2) < 1e-9)
    }

    @Test("beginNewSegment() 不帶取樣率：沿用原本的取樣率開新分段（睡眠喚醒後使用）")
    func explicitNewSegmentKeepsRate() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try append(Signal.constant(0.25, count: 3_000), to: recorder)
        try recorder.beginNewSegment()
        try append(Signal.constant(-0.25, count: 5_000), to: recorder)
        try recorder.close()

        let segments = try RecordingFiles.segments(in: tmp.url)
        #expect(segments.map(\.frameCount) == [3_000, 5_000])
        #expect(segments.map(\.sampleRate) == [rate, rate])
    }

    @Test("沒有寫入任何樣本時，不留下空的分段檔")
    func leavesNoEmptySegments() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try recorder.beginNewSegment()
        try recorder.close()

        #expect(try RecordingFiles.segments(in: tmp.url).isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.url.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".caf") }.isEmpty)
    }

    @Test("關檔之後再 append 會丟出錯誤，重複關檔不算錯")
    func appendAfterCloseThrows() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate)
        try append(Signal.constant(0.1, count: 100), to: recorder)
        try recorder.close()
        try recorder.close()

        #expect(throws: (any Error).self) {
            try Signal.constant(0.1, count: 100).withUnsafeBufferPointer { try recorder.append($0) }
        }
        #expect(try RecordingFiles.segments(in: tmp.url).map(\.frameCount) == [100])
    }

    @Test("會自動建立還不存在的資料夾")
    func createsDirectory() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let nested = tmp.url.appendingPathComponent("a/b/audio")

        let recorder = try SegmentedRecorder(directory: nested, sampleRate: rate)
        try append(Signal.constant(0.1, count: 100), to: recorder)
        try recorder.close()

        #expect(try RecordingFiles.segments(in: nested).count == 1)
    }

    @Test("segments(in:)：資料夾不存在回傳空陣列，不是分段檔的檔案會被忽略")
    func segmentListingIsTolerant() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        #expect(try RecordingFiles.segments(in: tmp.url.appendingPathComponent("missing")).isEmpty)

        let recorder = try SegmentedRecorder(directory: tmp.url, sampleRate: rate, segmentDuration: 1)
        try append(Signal.constant(0.1, count: 12_000), to: recorder)
        try recorder.close()
        try "not audio".write(to: tmp.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: tmp.url.appendingPathComponent(".DS_Store"))

        #expect(try RecordingFiles.segments(in: tmp.url).map(\.url.lastPathComponent) == ["000.caf", "001.caf"])
    }
}
