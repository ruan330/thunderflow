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

    public init(from sourceRate: Double, to targetRate: Double) throws {
        self.sourceRate = sourceRate
        self.targetRate = targetRate
    }

    /// 轉換一批樣本，結果依序交給 `output`（可能 0 次或好幾次）。
    public func convert(_ samples: UnsafeBufferPointer<Float>, into output: (UnsafeBufferPointer<Float>) -> Void) throws {}

    /// 沒有更多樣本了：把轉換器裡剩下的樣本交出來。之後再呼叫 `convert` 會丟出錯誤。重複呼叫不做任何事。
    public func finish(into output: (UnsafeBufferPointer<Float>) -> Void) throws {}
}
