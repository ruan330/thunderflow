import Darwin
import Foundation
import Synchronization

/// 量測用（DESIGN.md 9.8 節）：啟動參數 `-reportPerf YES` 時，每一場錄音在標準輸出印出
/// - `perf.startToCapture.ms`：按下開始到第一個樣本進來（`session.startToCapture`）
/// - `perf.mainThreadHitch.ms`：錄音中主執行緒最長的一次卡頓（`ui.mainThreadHitch`）
///
/// 沒有這個參數時什麼都不做，也不建立任何執行緒。時間一律用 `CLOCK_UPTIME_RAW`，
/// 和 `CaptureMixer.firstFramesUptimeNanoseconds` 同一個時鐘。
@MainActor
enum PerfProbe {
    static let enabled = UserDefaults.standard.bool(forKey: "reportPerf")

    private static var pressedAt: UInt64?
    private static var reportedStart = false
    private static var hitches: HitchWatch?

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// 使用者按下開始（`AppModel.start()` 的第一行）。
    static func startPressed() {
        guard enabled else { return }
        pressedAt = now()
        reportedStart = false
    }

    /// 錄音真的開始了：開始看主執行緒。
    static func recordingStarted() {
        guard enabled else { return }
        _ = hitches?.stop()
        hitches = HitchWatch()
    }

    /// 定期呼叫（錄音中的 ticker）：第一個樣本進來之後印一次。
    static func check(firstSample: UInt64?) {
        guard enabled, !reportedStart, let pressedAt, let firstSample else { return }
        reportedStart = true
        print(String(format: "perf.startToCapture.ms %.1f", Double(firstSample &- pressedAt) / 1_000_000))
        fflush(stdout)
    }

    /// 錄音結束：印出這一場主執行緒最長的卡頓。
    static func recordingStopped() {
        guard enabled, let watch = hitches else { return }
        hitches = nil
        let result = watch.stop()
        print(String(format: "perf.mainThreadHitch.ms %.1f pings %d", Double(result.worst) / 1_000_000, result.pings))
        fflush(stdout)
    }
}

/// 背景執行緒每 10 ms 請主執行緒執行一個空的工作，記下從送出到執行的最長延遲。
/// 上一個還沒執行時不送下一個，所以一次長的卡頓只算一次，也不會堆積。
private final class HitchWatch: Sendable {
    private struct State {
        var inFlight = false
        var worst: UInt64 = 0
        var pings = 0
        var stopped = false
    }
    private let state = Mutex(State())

    init() {
        let thread = Thread { [self] in run() }
        thread.name = "ThunderFlow.HitchWatch"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        while true {
            // nil：已經停止；false：上一個還在等主執行緒，這一輪不送
            let send: Bool? = state.withLock { s in
                if s.stopped { return nil }
                if s.inFlight { return false }
                s.inFlight = true
                return true
            }
            guard let send else { return }
            if send {
                let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                DispatchQueue.main.async { [self] in
                    let delay = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- sent
                    state.withLock {
                        $0.worst = max($0.worst, delay)
                        $0.pings += 1
                        $0.inFlight = false
                    }
                }
            }
            usleep(10_000)
        }
    }

    /// 停止並回傳最長的延遲（奈秒）與完成的次數。
    func stop() -> (worst: UInt64, pings: Int) {
        state.withLock {
            $0.stopped = true
            return ($0.worst, $0.pings)
        }
    }
}
