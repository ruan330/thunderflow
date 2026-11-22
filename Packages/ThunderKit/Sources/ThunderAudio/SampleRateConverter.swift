import AVFoundation
import Foundation

/// 把單聲道樣本從一個取樣率轉成另一個，串流進行（跨呼叫保留狀態）。
///
/// 錄音中途重新開始收音（裝置不見、睡眠醒來、換了輸出裝置）時，新的裝置取樣率可能不同（例如 AirPods 的麥克風是 24 kHz）：
/// 轉成這一場原本的取樣率再錄，錄音檔、音訊時間與送給引擎的音訊都不會變。
/// 在 Pump 的執行緒上使用，不在即時執行緒上。不是 thread-safe。
public final class SampleRateConverter {
    public let sourceRate: Double
    public let targetRate: Double
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private var isFinished = false
    private var hasInput = false

    private static let inputFrameCapacity: AVAudioFrameCount = 4_096

    public init(from sourceRate: Double, to targetRate: Double) throws {
        guard sourceRate.isFinite, sourceRate > 0, targetRate.isFinite, targetRate > 0,
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.inputFrameCapacity),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount((Double(Self.inputFrameCapacity) * targetRate / sourceRate).rounded(.up)) + 1_024)
        else { throw SampleRateConverterError.unsupported(sourceRate: sourceRate, targetRate: targetRate) }
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    /// 轉換一批樣本，結果依序交給 `output`（可能 0 次或好幾次）。
    public func convert(_ samples: UnsafeBufferPointer<Float>, into output: (UnsafeBufferPointer<Float>) -> Void) throws {
        guard !isFinished else { throw SampleRateConverterError.finished }
        guard var source = samples.baseAddress, samples.count > 0 else { return }
        hasInput = true
        var remaining = samples.count
        while remaining > 0 {
            let count = min(remaining, Int(inputBuffer.frameCapacity))
            inputBuffer.floatChannelData![0].update(from: source, count: count)
            inputBuffer.frameLength = AVAudioFrameCount(count)
            try drain(supplying: inputBuffer, into: output)
            source += count
            remaining -= count
        }
    }

    /// 沒有更多樣本了：把轉換器裡剩下的樣本交出來。之後再呼叫 `convert` 會丟出錯誤。重複呼叫不做任何事。
    public func finish(into output: (UnsafeBufferPointer<Float>) -> Void) throws {
        guard !isFinished else { return }
        isFinished = true
        if hasInput { try drain(supplying: nil, into: output) }
    }

    /// 把 `input` 交給轉換器並取出所有能取出的輸出；`input` 為 nil 表示沒有更多樣本，把轉換器裡剩下的都取出來。
    private func drain(supplying input: AVAudioPCMBuffer?, into output: (UnsafeBufferPointer<Float>) -> Void) throws {
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
                    // 這次的樣本都給了；轉換器先回傳目前做得出來的部分（.inputRanDry），下次再接著做
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw conversionError ?? SampleRateConverterError.conversionFailed }
            let produced = Int(outputBuffer.frameLength)
            if produced > 0 { output(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: produced)) }
            // .haveData：輸出緩衝區滿了，可能還有；.inputRanDry／.endOfStream：這次能取的都取完了
            guard status == .haveData, produced > 0 else { return }
        }
    }
}

enum SampleRateConverterError: Error, CustomStringConvertible {
    case unsupported(sourceRate: Double, targetRate: Double)
    case finished
    case conversionFailed

    var description: String {
        switch self {
        case .unsupported(let source, let target): "不支援的取樣率轉換：\(source) → \(target)"
        case .finished: "取樣率轉換已經結束，不能再送入樣本"
        case .conversionFailed: "取樣率轉換失敗"
        }
    }
}
