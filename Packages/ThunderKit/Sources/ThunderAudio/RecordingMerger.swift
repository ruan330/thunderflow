import AudioToolbox
import AVFoundation
import Foundation

public enum RecordingMergerError: Error, Equatable {
    /// 沒有任何聲音可以合併：沒有分段，或分段都是空的。
    case noAudio
    /// 取樣率轉換失敗。
    case conversionFailed
}

/// 合併錄音（結束處理的第 4 步）：把 CAF 分段依序接起來，編碼成一個 m4a（AAC、單聲道、64 kbps）。
///
/// - 一批一批地讀、轉、寫，不會把整場錄音載入記憶體。
/// - 取樣率用第一個分段的；其他取樣率的分段會先轉成它。AAC 不支援的取樣率（例如 96 kHz）
///   改用不超過它的最高支援取樣率（48 kHz）。
/// - 位元率是 64 kbps；取樣率太低、編碼器不接受 64 kbps 時（16 kHz 以下），用它接受的最高位元率。
/// - 先寫進目的地所在資料夾裡的暫存檔（`.<檔名>.<UUID>.tmp.m4a`），寫完、fsync 之後才改名成目的地，
///   所以目的地不會出現寫到一半的檔案；失敗時刪掉暫存檔。開始前會清掉上次中斷留下的暫存檔。
/// - 不會改動來源的分段檔。要不要刪除它們由呼叫端決定：先確認回傳的時長和分段的總長一致。
public enum RecordingMerger {
    private static let targetBitRate = 64_000
    private static let framesPerRead: AVAudioFrameCount = 32_768
    private static let temporarySuffix = ".tmp.m4a"

    /// 合併 `segments`（依陣列的順序），寫到 `url`，回傳成品實際的時長（秒，從寫好的檔案讀出來）。
    ///
    /// 沒有任何聲音可以合併時丟出 `RecordingMergerError.noAudio`，不建立檔案。
    /// 某個分段檔比它的檔頭宣稱的短（被截斷）時，合併讀得到的部分；回傳的時長因此會比分段的總長短，
    /// 呼叫端據此知道成品不完整。
    public static func merge(segments: [RecordingSegment], to url: URL) throws -> TimeInterval {
        try autoreleasepool {
            let sources = segments.filter { $0.frameCount > 0 }
            guard let first = sources.first else { throw RecordingMergerError.noAudio }
            let sampleRate = encodableSampleRate(for: first.sampleRate)
            removeLeftovers(of: url)
            // 副檔名要是 m4a，AVAudioFile 才知道要寫成 MPEG-4 的檔案
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)\(temporarySuffix)")
            var renamed = false
            defer { if !renamed { try? FileManager.default.removeItem(at: temporary) } }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate(for: sampleRate),
            ]
            let output = try AVAudioFile(
                forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            for segment in sources { try append(segment, to: output) }
            output.close()

            let mergedDuration = try Self.duration(of: temporary)
            // 先把內容送到磁碟再改名：呼叫端接下來可能就會刪掉 CAF 分段
            try synchronize(temporary)
            guard rename(temporary.path, url.path) == 0 else { throw posixError(errno, path: url.path) }
            renamed = true
            return mergedDuration
        }
    }

    /// 音訊檔的時長（秒）。
    public static func duration(of url: URL) throws -> TimeInterval {
        try autoreleasepool {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            return sampleRate > 0 ? Double(file.length) / sampleRate : 0
        }
    }

    // MARK: 讀、轉、寫

    /// 把一個分段接在 `output` 後面。取樣率（或聲道數）和成品不同時先轉換。
    private static func append(_ segment: RecordingSegment, to output: AVAudioFile) throws {
        let input = try AVAudioFile(forReading: segment.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = input.processingFormat
        let outputFormat = output.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerRead) else {
            throw RecordingMergerError.conversionFailed
        }
        if inputFormat == outputFormat {
            while try read(input, into: buffer) { try output.write(from: buffer) }
            return
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount((Double(framesPerRead) * ratio).rounded(.up)) + 1_024)
        else { throw RecordingMergerError.conversionFailed }
        while try read(input, into: buffer) {
            try convert(buffer, with: converter, into: converted, appendingTo: output)
        }
        // 這個分段結束：把轉換器裡剩下的樣本都取出來，總長度才會和來源一致
        try convert(nil, with: converter, into: converted, appendingTo: output)
    }

    /// 讀下一批樣本，讀完了回傳 false。
    /// 分段檔比檔頭宣稱的短（被截斷）時，`AVAudioFile` 會在實際的結尾丟出「檔案結束」，這裡當成讀完了。
    private static func read(_ input: AVAudioFile, into buffer: AVAudioPCMBuffer) throws -> Bool {
        guard input.framePosition < input.length else { return false }
        do {
            try input.read(into: buffer)
        } catch let error as NSError where error.code == Int(kAudioFileEndOfFileError) {
            return false
        }
        return buffer.frameLength > 0
    }

    /// 把 `input` 交給轉換器並把轉好的樣本寫進 `output`；`input` 為 nil 表示這個分段結束。
    private static func convert(
        _ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, into converted: AVAudioPCMBuffer,
        appendingTo output: AVAudioFile
    ) throws {
        var supplied = false
        while true {
            converted.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard let input else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if supplied {
                    // 這一批已經給了；轉換器先回傳目前做得出來的部分，下次再接著做
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw conversionError ?? RecordingMergerError.conversionFailed }
            if converted.frameLength > 0 { try output.write(from: converted) }
            // .haveData：輸出緩衝區滿了，可能還有；其他狀態表示這次能取的都取完了
            guard status == .haveData, converted.frameLength > 0 else { return }
        }
    }

    // MARK: 編碼器接受的格式

    /// AAC 編碼器接受的取樣率裡，最適合 `sampleRate` 的一個：本身就支援時原樣使用，
    /// 否則用不超過它的最高支援取樣率（都比它高時用最低的）。
    private static func encodableSampleRate(for sampleRate: Double) -> Double {
        let ranges = supportedSampleRateRanges()
        if ranges.contains(where: { $0.mMinimum <= sampleRate && sampleRate <= $0.mMaximum }) { return sampleRate }
        return ranges.map(\.mMaximum).filter { $0 <= sampleRate }.max() ?? ranges.map(\.mMinimum).min() ?? sampleRate
    }

    private static func supportedSampleRateRanges() -> [AudioValueRange] {
        var formatID = kAudioFormatMPEG4AAC
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var size: UInt32 = 0
        guard
            AudioFormatGetPropertyInfo(kAudioFormatProperty_AvailableEncodeSampleRates, specifierSize, &formatID, &size)
                == noErr, size > 0
        else { return fallbackSampleRateRanges }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.stride)
        guard
            AudioFormatGetProperty(
                kAudioFormatProperty_AvailableEncodeSampleRates, specifierSize, &formatID, &size, &ranges) == noErr,
            !ranges.isEmpty
        else { return fallbackSampleRateRanges }
        return ranges
    }

    /// 查不到編碼器支援的取樣率時用的清單（macOS 27 實測的結果）。
    private static var fallbackSampleRateRanges: [AudioValueRange] {
        [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].map {
            AudioValueRange(mMinimum: $0, mMaximum: $0)
        }
    }

    /// 這個取樣率下編碼器接受的位元率裡，不超過 64 kbps 的最高值。
    private static func bitRate(for sampleRate: Double) -> Int {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1_024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard
            let pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let aac = AVAudioFormat(streamDescription: &description),
            let rates = AVAudioConverter(from: pcm, to: aac)?.applicableEncodeBitRates?.map(\.intValue),
            !rates.isEmpty
        else { return targetBitRate }
        return rates.filter { $0 <= targetBitRate }.max() ?? rates.min() ?? targetBitRate
    }

    // MARK: 檔案

    /// 清掉上次合併到一半被中斷（例如程式被強制結束）留下的暫存檔。
    private static func removeLeftovers(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno, path: url.path) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(errno, path: url.path) }
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(path)：\(String(cString: strerror(code)))"])
    }
}
