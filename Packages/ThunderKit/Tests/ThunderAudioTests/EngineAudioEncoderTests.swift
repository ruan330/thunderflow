import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderTestKit

@Suite("EngineAudioEncoder：轉成引擎要的 24 kHz PCM16，並切成固定長度的包")
struct EngineAudioEncoderTests {
    /// 以每次 `pieceSize` 個樣本送入，最後收尾，回傳全部的包。
    private func encodeAll(_ encoder: EngineAudioEncoder, _ samples: [Float], pieceSize: Int = 960) throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + pieceSize, samples.count)
            chunks += try samples[offset..<end].withUnsafeBufferPointer { try encoder.encode($0) }
            offset = end
        }
        if let tail = try encoder.finish() { chunks.append(tail) }
        return chunks
    }

    private func totalDuration(_ chunks: [AudioChunk]) -> Double {
        chunks.reduce(0) { $0 + $1.duration }
    }

    @Test("每包剛好 200 ms（4,800 個樣本），只有最後一包可以比較短；開始時間一包接一包")
    func chunksAreFixedSizeAndContiguous() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 48_000)
        let input = Signal.sine(frequency: 1_000, sampleRate: 48_000, duration: 10.07)

        let chunks = try encodeAll(encoder, input)

        #expect(chunks.count == 51)
        #expect(chunks.dropLast().allSatisfy { $0.frameCount == 4_800 })
        #expect(chunks.allSatisfy { $0.frameCount > 0 && $0.frameCount <= 4_800 })
        #expect(chunks.allSatisfy { $0.sampleRate == 24_000 })
        #expect(chunks.allSatisfy { $0.pcm16.count == $0.frameCount * 2 })
        let firstMisplaced = chunks.enumerated().first { abs($0.element.startTime.seconds - Double($0.offset) * 0.2) > 1e-9 }
        #expect(firstMisplaced == nil, "第 \(firstMisplaced?.offset ?? -1) 包的開始時間不對")
        #expect(abs(totalDuration(chunks) - 10.07) < 0.02)
    }

    @Test("各種來源取樣率：轉完的總長度不變（誤差 20 ms 以內）", arguments: [16_000.0, 24_000, 44_100, 48_000, 96_000])
    func preservesDuration(sourceRate: Double) throws {
        let encoder = try EngineAudioEncoder(sourceRate: sourceRate)
        let input = Signal.sine(frequency: 440, sampleRate: sourceRate, duration: 5)

        let chunks = try encodeAll(encoder, input, pieceSize: Int(sourceRate / 50))

        #expect(abs(totalDuration(chunks) - 5) < 0.02)
        #expect(chunks.dropLast().allSatisfy { $0.frameCount == 4_800 })
    }

    @Test("長時間不累積誤差：5 分鐘的音訊，總長度誤差仍在 20 ms 以內")
    func noDriftOverTime() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 44_100)
        let oneSecond = Signal.sine(frequency: 441, sampleRate: 44_100, duration: 1)
        var frames = 0
        var lastStart = -1.0
        var startsKeepIncreasing = true

        for _ in 0..<300 {
            for chunk in try oneSecond.withUnsafeBufferPointer({ try encoder.encode($0) }) {
                frames += chunk.frameCount
                if chunk.startTime.seconds <= lastStart { startsKeepIncreasing = false }
                lastStart = chunk.startTime.seconds
            }
        }
        if let tail = try encoder.finish() { frames += tail.frameCount }

        #expect(startsKeepIncreasing)
        #expect(abs(Double(frames) / 24_000 - 300) < 0.02)
    }

    @Test("頻率與音量保留：1 kHz 的正弦波轉完還是 1 kHz，振幅誤差 3% 以內")
    func preservesFrequencyAndLevel() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 48_000)
        let input = Signal.sine(frequency: 1_000, sampleRate: 48_000, duration: 10, amplitude: 0.5)

        let pcm = Signal.int16Samples(of: try encodeAll(encoder, input))

        #expect(abs(Signal.zeroCrossings(pcm) - 20_000) <= 40)
        // 開頭與結尾各略過 0.1 秒：那是重取樣濾波器的暫態
        guard pcm.count > 4_800 else {
            Issue.record("輸出太短：\(pcm.count) 個樣本")
            return
        }
        let peak = pcm[2_400..<(pcm.count - 2_400)].reduce(0) { max($0, abs(Int($1))) }
        #expect(abs(Double(peak) / 32_767 - 0.5) < 0.015)
    }

    @Test("超出 ±1.0 的樣本會被限幅，不會繞回成反向的值")
    func clipsWithoutWrapping() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 48_000)
        let input = Signal.sine(frequency: 100, sampleRate: 48_000, duration: 1, amplitude: 1.5)

        let pcm = Signal.int16Samples(of: try encodeAll(encoder, input))

        #expect((pcm.max() ?? 0) >= 32_000)
        #expect((pcm.min() ?? 0) <= -32_000)
        // 繞回會造成相鄰樣本從最大值跳到最小值；100 Hz 的波形相鄰樣本的正常差距不到 1,300
        let largestStep = zip(pcm, pcm.dropFirst()).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        #expect(largestStep < 8_000)
    }

    @Test("來源已經是 24 kHz 時不重取樣：樣本逐一對應")
    func passthroughAtTargetRate() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 24_000)
        let input = (0..<24_000).map { Float(($0 % 1_801) - 900) / 1_000 }

        let chunks = try encodeAll(encoder, input, pieceSize: 500)
        let pcm = Signal.int16Samples(of: chunks)

        #expect(chunks.count == 5)
        #expect(pcm.count == input.count)
        guard pcm.count == input.count else { return }
        let worst = zip(pcm, input).reduce(0) { max($0, abs(Int($1.0) - Int(($1.1 * 32_767).rounded()))) }
        #expect(worst <= 1)
    }

    @Test("沒有任何音訊時，收尾不會產生空的包")
    func finishWithNothing() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 48_000)

        #expect(try encoder.finish() == nil)
    }

    @Test("可以自訂每包長度與目標取樣率")
    func customChunking() throws {
        let encoder = try EngineAudioEncoder(sourceRate: 48_000, targetRate: 16_000, chunkDuration: 0.1)
        let input = Signal.sine(frequency: 440, sampleRate: 48_000, duration: 2)

        let chunks = try encodeAll(encoder, input)

        #expect(chunks.allSatisfy { $0.sampleRate == 16_000 })
        #expect(chunks.dropLast().allSatisfy { $0.frameCount == 1_600 })
        #expect(abs(totalDuration(chunks) - 2) < 0.02)
    }
}
