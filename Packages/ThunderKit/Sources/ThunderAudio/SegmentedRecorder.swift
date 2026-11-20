import Accelerate
import AudioToolbox
import AVFoundation
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
///   檔案不需要修復就能開啟。（`AVAudioFile` 寫 CAF 是直接寫進檔案的，錄音中資料區塊的長度標成 -1，
///   讀的時候依檔案大小計算，所以別人不必等關檔就能讀到完整的資料。）
/// - 每滿 `segmentDuration`（`round(segmentDuration × 取樣率)` 個樣本）就換檔，一次 `append`
///   跨過分段邊界時會拆開寫，所以除了最後一段，每段的長度都一樣。
/// - 分段檔在第一個樣本進來時才建立，所以不會留下空的分段檔。
/// - 超出 ±1.0 的樣本會先限幅，不會在轉成 16-bit 時繞回成反向的值。
/// - 每寫滿約 5 秒的音訊，就在背景對目前的分段做一次 fsync（另開一個唯讀的檔案描述子），
///   把斷電或整台電腦當掉時的損失限制在約 5 秒內；錄音路徑不等它完成。分段結束時也會 fsync 一次。
/// - 不是 thread-safe：只能由 Pump 的執行緒使用。
public final class SegmentedRecorder {
    private let directory: URL
    private let segmentDuration: TimeInterval
    private var sampleRate: Double
    /// 每個分段的樣本數：`round(segmentDuration × sampleRate)`。
    private var framesPerSegment: Int64
    /// 每寫這麼多個樣本就 fsync 一次（約 5 秒）。
    private var framesPerSync: Int64

    /// 目前的分段；還沒有樣本進來時是 nil。
    private var file: AVAudioFile?
    private var fileURL: URL?
    /// 目前（或下一個）分段的序號。
    private var index = 0
    private var framesInSegment: Int64 = 0
    private var framesSinceSync: Int64 = 0
    /// 已經結束的分段合計的樣本數與長度。
    private var finishedFrames: Int64 = 0
    private var finishedDuration: TimeInterval = 0
    /// 交給 `AVAudioFile` 的緩衝區，事先配置好重複使用（取樣率改變時重建）。
    private var buffer: AVAudioPCMBuffer?
    private var isClosed = false

    private static let bufferFrameCapacity: AVAudioFrameCount = 8_192
    private static let syncInterval: TimeInterval = 5
    private static let syncQueue = DispatchQueue(label: "ThunderFlow.SegmentedRecorder.fsync", qos: .utility)

    /// - Parameters:
    ///   - directory: 分段檔要放的資料夾，不存在會自動建立。
    ///   - sampleRate: 來源取樣率（單聲道）。
    ///   - segmentDuration: 每個分段的長度（秒）。
    public init(directory: URL, sampleRate: Double, segmentDuration: TimeInterval = 600) throws {
        guard sampleRate.isFinite, sampleRate > 0 else { throw SegmentedRecorderError.invalidSampleRate(sampleRate) }
        guard segmentDuration.isFinite, segmentDuration > 0 else {
            throw SegmentedRecorderError.invalidSegmentDuration(segmentDuration)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.segmentDuration = segmentDuration
        self.sampleRate = sampleRate
        framesPerSegment = Self.frames(segmentDuration, at: sampleRate)
        framesPerSync = Self.frames(Self.syncInterval, at: sampleRate)
        Self.warmUp()
    }

    /// 累計寫入的樣本數（所有分段合計）。
    public var framesWritten: Int64 { finishedFrames + framesInSegment }

    /// 累計錄音長度（秒）：各分段的樣本數除以各自的取樣率後加總。
    public var duration: TimeInterval { finishedDuration + Double(framesInSegment) / sampleRate }

    /// 寫入樣本。超出 ±1.0 的值會被限幅。
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !isClosed else { throw SegmentedRecorderError.closed }
        guard var source = samples.baseAddress else { return }
        var remaining = samples.count
        while remaining > 0 {
            let (file, buffer) = try openSegmentIfNeeded()
            let count = Int(min(Int64(remaining), framesPerSegment - framesInSegment, Int64(buffer.frameCapacity)))
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(source, 1, &low, &high, buffer.floatChannelData![0], 1, vDSP_Length(count))
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            source += count
            remaining -= count
            framesInSegment += Int64(count)
            framesSinceSync += Int64(count)
            if framesSinceSync >= framesPerSync {
                framesSinceSync = 0
                scheduleSync()
            }
            if framesInSegment >= framesPerSegment { finishSegment() }
        }
    }

    /// 結束目前的分段，之後的樣本寫進新的分段。
    /// 用於裝置取樣率改變（傳入新的取樣率）或睡眠喚醒之後。
    /// 目前的分段還沒有任何樣本時不會留下空檔，序號也不會跳號。
    public func beginNewSegment(sampleRate newRate: Double? = nil) throws {
        guard !isClosed else { throw SegmentedRecorderError.closed }
        finishSegment()
        guard let newRate, newRate != sampleRate else { return }
        guard newRate.isFinite, newRate > 0 else { throw SegmentedRecorderError.invalidSampleRate(newRate) }
        sampleRate = newRate
        framesPerSegment = Self.frames(segmentDuration, at: newRate)
        framesPerSync = Self.frames(Self.syncInterval, at: newRate)
        buffer = nil
    }

    /// 關檔。之後再 `append` 會丟出錯誤。沒有寫入任何樣本時不會留下空檔。重複呼叫不算錯。
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        finishSegment()
    }

    // MARK: 分段

    private func openSegmentIfNeeded() throws -> (AVAudioFile, AVAudioPCMBuffer) {
        if let file, let buffer { return (file, buffer) }
        let url = directory.appendingPathComponent(RecordingFiles.fileName(forIndex: index))
        let file = try AVAudioFile(
            forWriting: url, settings: Self.fileSettings(sampleRate: sampleRate), commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let buffer: AVAudioPCMBuffer
        if let existing = self.buffer, existing.format == file.processingFormat {
            buffer = existing
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.bufferFrameCapacity)
            else { throw SegmentedRecorderError.invalidSampleRate(sampleRate) }
            buffer = created
        }
        self.file = file
        self.buffer = buffer
        fileURL = url
        framesInSegment = 0
        framesSinceSync = 0
        return (file, buffer)
    }

    /// 關閉目前的分段（寫入最後的檔頭）並在背景 fsync；沒有開啟中的分段就不做任何事。
    private func finishSegment() {
        guard let file else { return }
        file.close()
        scheduleSync()
        self.file = nil
        fileURL = nil
        finishedFrames += framesInSegment
        finishedDuration += Double(framesInSegment) / sampleRate
        framesInSegment = 0
        framesSinceSync = 0
        index += 1
    }

    /// 在背景把目前分段已經寫入的資料 fsync 到磁碟。另開唯讀的描述子，錄音路徑不等它完成。
    private func scheduleSync() {
        guard let fileURL else { return }
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        Self.syncQueue.async {
            fsync(descriptor)
            Darwin.close(descriptor)
        }
    }

    private static func frames(_ seconds: TimeInterval, at sampleRate: Double) -> Int64 {
        max(1, Int64((seconds * sampleRate).rounded()))
    }

    static func fileSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// 一個程序裡第一次建立 CAF 檔時，要先載入 AudioToolbox 的檔案元件與格式轉換器（實測約 8–13 ms）。
    /// 在建構時先載入，第一個樣本進來、建立第一個分段檔時就只要約 0.3 ms，不會拖住錄音路徑。
    /// 只做一次，而且不會建立任何檔案。
    private static func warmUp() {
        _ = warmedUp
    }

    private static let warmedUp: Bool = {
        var size: UInt32 = 0
        _ = AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_WritableTypes, 0, nil, &size)
        guard
            let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
            let stored = AVAudioFormat(settings: fileSettings(sampleRate: 48_000))
        else { return false }
        return AVAudioConverter(from: client, to: stored) != nil
    }()
}

enum SegmentedRecorderError: Error, CustomStringConvertible {
    case closed
    case invalidSampleRate(Double)
    case invalidSegmentDuration(TimeInterval)

    var description: String {
        switch self {
        case .closed: "錄音已經關檔，不能再寫入"
        case .invalidSampleRate(let rate): "不支援的取樣率：\(rate)"
        case .invalidSegmentDuration(let duration): "分段長度必須大於 0：\(duration)"
        }
    }
}

/// 讀回分段錄音（復原、合併、測試用）。
public enum RecordingFiles {
    /// 列出資料夾裡的分段檔，依序號排序，並讀出每段的取樣率與樣本數。
    /// 資料夾不存在時回傳空陣列；不是分段檔的檔案會被忽略。
    ///
    /// 分段檔是檔名為三位數以上序號的 `.caf`（`000.caf`、`001.caf`……）。錄音中的分段也讀得到，
    /// 長度是目前已經寫入的樣本數。打不開的分段檔（程式剛好在建立檔頭的瞬間被殺掉，裡面沒有任何聲音）會被略過。
    public static func segments(in directory: URL) throws -> [RecordingSegment] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return [] }
        var segments: [RecordingSegment] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard let index = segmentIndex(fileName: name) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            segments.append(
                RecordingSegment(url: url, index: index, sampleRate: file.fileFormat.sampleRate, frameCount: file.length))
        }
        return segments.sorted { $0.index < $1.index }
    }

    public static func totalDuration(of segments: [RecordingSegment]) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    public static func totalFrames(of segments: [RecordingSegment]) -> Int64 {
        segments.reduce(0) { $0 + $1.frameCount }
    }

    /// 讀出一個分段的全部樣本（-1.0 到 1.0）。
    public static func readSamples(of segment: RecordingSegment) throws -> [Float] {
        let file = try AVAudioFile(forReading: segment.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(clamping: file.length)
        guard frameCount > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw SegmentedRecorderError.invalidSampleRate(file.processingFormat.sampleRate)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// 第 `index` 段的檔名：至少三位數的序號，例如 `000.caf`。
    static func fileName(forIndex index: Int) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits + ".caf"
    }

    /// 從檔名取出分段序號；不是分段檔就回傳 nil。
    static func segmentIndex(fileName name: String) -> Int? {
        guard name.hasSuffix(".caf") else { return nil }
        let stem = name.dropLast(4)
        guard stem.count >= 3, stem.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(stem)
    }
}
