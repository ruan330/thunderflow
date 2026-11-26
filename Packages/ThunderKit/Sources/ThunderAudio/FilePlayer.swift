import AVFoundation
import Foundation

/// 把音檔當成來源：用一條專用執行緒，以即時速度把樣本寫進 RingBuffer。
final class FilePlayer: @unchecked Sendable {
    // @unchecked Sendable：`stopped` 由鎖保護；`file`、`buffer` 只在播放的那一條執行緒上使用。
    let sampleRate: Double
    var onEnded: (@Sendable () -> Void)?
    private let file: AVAudioFile
    private let ring: RingBuffer
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, ring: RingBuffer) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioCaptureError.unreadableFile(error.localizedDescription)
        }
        sampleRate = file.processingFormat.sampleRate
        self.ring = ring
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "ThunderFlow.FilePlayer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        let format = file.processingFormat
        let framesPerTick = AVAudioFrameCount(max(1, Int(sampleRate / 100)))  // 10 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerTick) else { return }
        var mono = [Float](repeating: 0, count: Int(framesPerTick))
        let started = ContinuousClock.now
        var played = 0
        while !isStopped {
            do { try file.read(into: buffer, frameCount: framesPerTick) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for index in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][index] }
                mono[index] = sum / Float(channelCount)
            }
            _ = mono.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
            played += frames
            // 照音檔的時間走：播到哪裡，就等到那個時間
            let due = started + .seconds(Double(played) / sampleRate)
            let wait = due - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) * 1e-18) }
        }
        if !isStopped { onEnded?() }
    }
}
