import Accelerate
import AVFoundation
import Foundation
import ThunderCore

#if _endian(big)
    #error("AudioChunk 的 PCM16 是 little-endian，這裡直接複製記憶體裡的 Int16，只適用於 little-endian 的平台")
#endif

/// 把來源音訊（單聲道 Float32、任意取樣率）轉成引擎要的格式：
/// 16-bit PCM、`targetRate`，並切成固定長度的包。
///
/// 每包的 `startTime` 一包接一包，從 0 開始。不是 thread-safe：只能由 Pump 的執行緒使用。
///
/// - 每包剛好 `round(chunkDuration × targetRate)` 個樣本，只有 `finish()` 回傳的最後一包可以比較短；
///   第 n 包的 `startTime` 是 n × 每包樣本數 ÷ `targetRate`（也就是 n × `chunkDuration`）。
/// - 來源取樣率等於 `targetRate` 時不重取樣，樣本逐一對應（限幅後四捨五入）。
/// - 其他取樣率用 `AVAudioConverter` 串流轉換。它預設的 prime 方式讓輸出與輸入對齊、沒有延遲，
///   代價是最後幾個樣本（實測 4–24 個，不到 1 ms）要等 `finish()` 收尾時才吐出來；
///   收尾之後總長度與來源完全一致，長時間也不會累積誤差。
/// - 超出 ±1.0 的值會被限幅（重取樣之前先限幅，轉成 16-bit 時再限幅一次，濾波器的過衝也不會繞回）。
/// - 緩衝區都在建立時配置好重複使用，`encode` 只會為湊滿的包配置 `Data`。
public final class EngineAudioEncoder {
    private let targetRate: Int
    private let framesPerChunk: Int
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer?
    /// 正在湊的那一包（16-bit 樣本）。
    private let pending: UnsafeMutablePointer<Int16>
    private var pendingCount = 0
    /// 轉成 16-bit 之前的暫存區（限幅、放大）。
    private let scratch: UnsafeMutablePointer<Float>
    private var chunkIndex = 0
    private var hasInput = false
    private var isFinished = false

    private static let inputFrameCapacity: AVAudioFrameCount = 8_192

    public init(sourceRate: Double, targetRate: Int = 24_000, chunkDuration: TimeInterval = 0.2) throws {
        guard sourceRate.isFinite, sourceRate > 0, targetRate > 0 else {
            throw EngineAudioEncoderError.invalidFormat(sourceRate: sourceRate, targetRate: targetRate)
        }
        let framesPerChunk = Int((chunkDuration * Double(targetRate)).rounded())
        guard chunkDuration.isFinite, framesPerChunk > 0 else {
            throw EngineAudioEncoderError.invalidChunkDuration(chunkDuration)
        }
        self.targetRate = targetRate
        self.framesPerChunk = framesPerChunk

        if sourceRate == Double(targetRate) {
            converter = nil
            inputBuffer = nil
            outputBuffer = nil
        } else {
            guard
                let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false),
                let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.inputFrameCapacity),
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(
                        (Double(Self.inputFrameCapacity) * Double(targetRate) / sourceRate).rounded(.up)) + 1_024)
            else { throw EngineAudioEncoderError.invalidFormat(sourceRate: sourceRate, targetRate: targetRate) }
            self.converter = converter
            self.inputBuffer = inputBuffer
            self.outputBuffer = outputBuffer
        }
        pending = .allocate(capacity: framesPerChunk)
        pending.initialize(repeating: 0, count: framesPerChunk)
        scratch = .allocate(capacity: framesPerChunk)
        scratch.initialize(repeating: 0, count: framesPerChunk)
    }

    deinit {
        pending.deallocate()
        scratch.deallocate()
    }

    /// 送入來源樣本，回傳這次湊滿的包（可能是 0 包或多包）。超出 ±1.0 的值會被限幅。
    /// `finish()` 之後再呼叫會丟出錯誤。
    public func encode(_ samples: UnsafeBufferPointer<Float>) throws -> [AudioChunk] {
        guard !isFinished else { throw EngineAudioEncoderError.finished }
        guard var source = samples.baseAddress, samples.count > 0 else { return [] }
        hasInput = true
        var chunks: [AudioChunk] = []
        guard let converter, let inputBuffer else {
            appendOutput(source, count: samples.count, to: &chunks)
            return chunks
        }
        var remaining = samples.count
        while remaining > 0 {
            let count = min(remaining, Int(inputBuffer.frameCapacity))
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(source, 1, &low, &high, inputBuffer.floatChannelData![0], 1, vDSP_Length(count))
            inputBuffer.frameLength = AVAudioFrameCount(count)
            try convert(with: converter, input: inputBuffer, to: &chunks)
            source += count
            remaining -= count
        }
        return chunks
    }

    /// 沒有更多音訊了：回傳最後一包不滿的音訊，沒有剩餘則回傳 nil。
    ///
    /// 重取樣器收尾時吐出的最後幾個樣本如果剛好讓這一包超過一包的長度，
    /// 只回傳滿的那一包，超出的部分（最多是重取樣器保留的那幾個樣本，不到 1 ms）捨棄，
    /// 以維持「每包都不超過 `chunkDuration`」。重複呼叫回傳 nil。
    public func finish() throws -> AudioChunk? {
        guard !isFinished else { return nil }
        isFinished = true
        var chunks: [AudioChunk] = []
        if let converter, hasInput {
            try convert(with: converter, input: nil, to: &chunks)
        }
        if let full = chunks.first { return full }
        guard pendingCount > 0 else { return nil }
        return makeChunk(frameCount: pendingCount)
    }

    // MARK: 轉換

    /// 把 `input` 交給轉換器並取出所有能取出的輸出；`input` 為 nil 表示音訊結束，把轉換器裡剩下的都取出來。
    private func convert(with converter: AVAudioConverter, input: AVAudioPCMBuffer?, to chunks: inout [AudioChunk]) throws {
        guard let outputBuffer else { return }
        var supplied = false
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let input else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if supplied {
                    // 這次的樣本都給了；轉換器會先回傳目前做得出來的部分（.inputRanDry），下次再接著做
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw conversionError ?? EngineAudioEncoderError.conversionFailed
            }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 {
                appendOutput(outputBuffer.floatChannelData![0], count: produced, to: &chunks)
            }
            // .haveData：輸出緩衝區滿了，可能還有；.inputRanDry／.endOfStream：這次能取的都取完了
            guard status == .haveData, produced > 0 else { return }
        }
    }

    /// 把目標取樣率的樣本限幅、轉成 16-bit 放進正在湊的那一包；湊滿就切出一包。
    private func appendOutput(_ samples: UnsafePointer<Float>, count: Int, to chunks: inout [AudioChunk]) {
        var offset = 0
        while offset < count {
            let take = min(count - offset, framesPerChunk - pendingCount)
            var low: Float = -1
            var high: Float = 1
            var scale: Float = 32_767
            vDSP_vclip(samples + offset, 1, &low, &high, scratch, 1, vDSP_Length(take))
            vDSP_vsmul(scratch, 1, &scale, scratch, 1, vDSP_Length(take))
            // 四捨五入到最接近的整數；範圍已經限制在 ±32,767，不會溢位
            vDSP_vfixr16(scratch, 1, pending + pendingCount, 1, vDSP_Length(take))
            pendingCount += take
            offset += take
            if pendingCount == framesPerChunk {
                chunks.append(makeChunk(frameCount: framesPerChunk))
            }
        }
    }

    private func makeChunk(frameCount: Int) -> AudioChunk {
        let chunk = AudioChunk(
            pcm16: Data(bytes: pending, count: frameCount * MemoryLayout<Int16>.stride),
            sampleRate: targetRate,
            startTime: AudioTime(seconds: Double(chunkIndex * framesPerChunk) / Double(targetRate)))
        chunkIndex += 1
        pendingCount = 0
        return chunk
    }
}

enum EngineAudioEncoderError: Error, CustomStringConvertible {
    case invalidFormat(sourceRate: Double, targetRate: Int)
    case invalidChunkDuration(TimeInterval)
    case conversionFailed
    case finished

    var description: String {
        switch self {
        case .invalidFormat(let source, let target): "不支援的取樣率轉換：\(source) Hz → \(target) Hz"
        case .invalidChunkDuration(let duration): "每包長度必須至少一個樣本：\(duration) 秒"
        case .conversionFailed: "取樣率轉換失敗"
        case .finished: "已經收尾，不能再送入音訊"
        }
    }
}
