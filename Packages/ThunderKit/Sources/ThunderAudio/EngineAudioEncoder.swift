import Foundation
import ThunderCore

/// 把來源音訊（單聲道 Float32、任意取樣率）轉成引擎要的格式：
/// 16-bit PCM、`targetRate`，並切成固定長度的包。
///
/// 每包的 `startTime` 一包接一包，從 0 開始。不是 thread-safe：只能由 Pump 的執行緒使用。
public final class EngineAudioEncoder {
    public init(sourceRate: Double, targetRate: Int = 24_000, chunkDuration: TimeInterval = 0.2) throws {
        throw NotYetImplemented("EngineAudioEncoder.init")
    }

    /// 送入來源樣本，回傳這次湊滿的包（可能是 0 包或多包）。超出 ±1.0 的值會被限幅。
    public func encode(_ samples: UnsafeBufferPointer<Float>) throws -> [AudioChunk] {
        throw NotYetImplemented("EngineAudioEncoder.encode(_:)")
    }

    /// 沒有更多音訊了：回傳最後一包不滿的音訊，沒有剩餘則回傳 nil。
    public func finish() throws -> AudioChunk? {
        throw NotYetImplemented("EngineAudioEncoder.finish()")
    }
}
