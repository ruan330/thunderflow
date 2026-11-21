import Foundation

/// 送給引擎的一包音訊：16-bit PCM、little-endian、單聲道。
public struct AudioChunk: Sendable, Equatable {
    public var pcm16: Data
    public var sampleRate: Int
    /// 這包第一個樣本在音訊時間軸上的位置。
    public var startTime: AudioTime

    public init(pcm16: Data, sampleRate: Int, startTime: AudioTime) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var frameCount: Int { pcm16.count / 2 }
    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
    public var endTime: AudioTime { startTime + duration }
}
