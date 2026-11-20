import Foundation
import ThunderCore

/// 錄音的一個分段檔。
public struct RecordingSegment: Sendable, Equatable {
    public var url: URL
    /// 第幾段，從 0 開始。檔名是三位數的序號，例如 `000.caf`。
    public var index: Int
    public var sampleRate: Double
    public var frameCount: Int64

    public init(url: URL, index: Int, sampleRate: Double, frameCount: Int64) {
        self.url = url
        self.index = index
        self.sampleRate = sampleRate
        self.frameCount = frameCount
    }

    public var duration: TimeInterval { Double(frameCount) / sampleRate }
}

/// 把單聲道樣本寫成一連串 CAF 分段檔（16-bit PCM）。
///
/// - 每次 `append` 返回時，資料已經交給作業系統：程式被強制結束，已 append 的聲音也不會遺失，
///   檔案不需要修復就能開啟。
/// - 每滿 `segmentDuration` 就換檔，所以除了最後一段，每段的長度都一樣。
/// - 不是 thread-safe：只能由 Pump 的執行緒使用。
public final class SegmentedRecorder {
    /// - Parameters:
    ///   - directory: 分段檔要放的資料夾，不存在會自動建立。
    ///   - sampleRate: 來源取樣率（單聲道）。
    ///   - segmentDuration: 每個分段的長度（秒）。
    public init(directory: URL, sampleRate: Double, segmentDuration: TimeInterval = 600) throws {
        throw NotYetImplemented("SegmentedRecorder.init")
    }

    /// 累計寫入的樣本數（所有分段合計）。
    public var framesWritten: Int64 { 0 }

    /// 累計錄音長度（秒）：各分段的樣本數除以各自的取樣率後加總。
    public var duration: TimeInterval { 0 }

    /// 寫入樣本。超出 ±1.0 的值會被限幅。
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        throw NotYetImplemented("SegmentedRecorder.append(_:)")
    }

    /// 結束目前的分段，之後的樣本寫進新的分段。
    /// 用於裝置取樣率改變（傳入新的取樣率）或睡眠喚醒之後。
    public func beginNewSegment(sampleRate: Double? = nil) throws {
        throw NotYetImplemented("SegmentedRecorder.beginNewSegment(sampleRate:)")
    }

    /// 關檔。之後再 `append` 會丟出錯誤。沒有寫入任何樣本時不會留下空檔。
    public func close() throws {
        throw NotYetImplemented("SegmentedRecorder.close()")
    }
}

/// 讀回分段錄音（復原、合併、測試用）。
public enum RecordingFiles {
    /// 列出資料夾裡的分段檔，依序號排序，並讀出每段的取樣率與樣本數。
    /// 資料夾不存在時回傳空陣列；不是分段檔的檔案會被忽略。
    public static func segments(in directory: URL) throws -> [RecordingSegment] {
        throw NotYetImplemented("RecordingFiles.segments(in:)")
    }

    public static func totalDuration(of segments: [RecordingSegment]) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    public static func totalFrames(of segments: [RecordingSegment]) -> Int64 {
        segments.reduce(0) { $0 + $1.frameCount }
    }

    /// 讀出一個分段的全部樣本（-1.0 到 1.0）。
    public static func readSamples(of segment: RecordingSegment) throws -> [Float] {
        throw NotYetImplemented("RecordingFiles.readSamples(of:)")
    }
}
