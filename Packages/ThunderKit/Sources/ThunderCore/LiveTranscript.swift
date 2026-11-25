import Darwin
import Foundation
import Synchronization

/// 給 AI agent 讀的即時逐字稿：`<場次資料夾>/live-transcript.txt`（DESIGN.md 5.9 節，D34）。
extension SessionDirectory {
    /// 錄音中的即時逐字稿。基本逐字稿做好時刪除，之後改看 `transcript.md`。
    public var liveTranscriptURL: URL { url.appendingPathComponent("live-transcript.txt") }
    /// 工作坊教材：每次下載一個子資料夾。
    public var workshopURL: URL { url.appendingPathComponent("workshop", isDirectory: true) }
}

/// 即時逐字稿的一行。
public enum LiveTranscriptEntry: Sendable, Equatable {
    /// 一段英文確定了（`segment` 是段號；同一段之後再確定一次，例如補上晚到的標點，不再寫）。
    case speech(String, segment: Int?)
    /// 使用者標記的重點。
    case marker
    case paused
    case resumed
    /// 沒有字幕的一段：引擎回報的缺口，或錄音中斷（`AudioGap.isInterruption`）。
    case gap(AudioGap)
}

/// 寫即時逐字稿：建立時寫入兩行說明，之後每一筆寫一行，只往後加。可以從任何執行緒呼叫。
///
/// 格式（DESIGN.md 5.9 節）：
///
///     # ThunderFlow 即時逐字稿｜GameDay｜2026-12-01 10:30 開始
///     # 英文由語音自動辨識，可能有錯字；⚑ 是使用者標記的重點
///     [10:30:12] So today each team gets its own AWS account.
///     [10:42:05] ⚑ 標記
///
/// 每一行前面是寫入當下的時刻（不是音訊時間：暫停前後才對得上牆上的時鐘），一行用一次 write(2) 寫出。
/// 寫入失敗不丟出錯誤：這個檔只是給 agent 讀的副本，不能影響錄音。資料來源永遠是日誌。
public final class LiveTranscriptWriter: Sendable {
    private struct State {
        /// 檔案描述子；關檔之後是 -1。
        var descriptor: Int32
        /// 最後寫過的段號。段號只增不減，同一段（或更早的段）再確定一次就不再寫。
        var lastSegment: Int?
    }

    private let state: Mutex<State>
    private let path: String
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    /// 建立檔案（已經存在就從頭寫）並寫入兩行說明。
    ///
    /// - Parameters:
    ///   - title: 場次的標題（空的就不寫）。
    ///   - startedAt: 開始的時間，寫在說明裡。
    ///   - timeZone: 時刻用的時區。
    ///   - clock: 每一行前面的時刻（寫入當下）。
    public init(
        url: URL, title: String, startedAt: Date, timeZone: TimeZone = .current,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.clock = clock
        let path = url.path
        self.path = path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FileIO.posixError(errno, path: path) }
        do {
            try Self.write(Self.header(title: title, startedAt: startedAt, calendar: calendar), to: fd, path: path)
        } catch {
            Darwin.close(fd)
            throw error
        }
        state = Mutex(State(descriptor: fd))
    }

    deinit { close() }

    /// 寫一行。關檔之後、沒有內容（只有空白的英文、同一段的第二次）時什麼都不做。
    public func append(_ entry: LiveTranscriptEntry) {
        state.withLock { state in
            guard state.descriptor >= 0, let text = Self.text(for: entry, &state) else { return }
            try? Self.write("[\(Self.clockTime(clock(), calendar: calendar))] \(text)\n", to: state.descriptor, path: path)
        }
    }

    /// 關檔。重複呼叫不算錯；關檔之後的 `append` 什麼都不做。
    public func close() {
        state.withLock { state in
            guard state.descriptor >= 0 else { return }
            Darwin.close(state.descriptor)
            state.descriptor = -1
        }
    }

    // MARK: 內容

    private static func text(for entry: LiveTranscriptEntry, _ state: inout State) -> String? {
        switch entry {
        case .speech(let text, let segment):
            let line = oneLine(text)
            guard !line.isEmpty else { return nil }
            if let segment {
                if let last = state.lastSegment, segment <= last { return nil }
                state.lastSegment = segment
            }
            return line
        case .marker:
            return "⚑ 標記"
        case .paused:
            return "—— 暫停 ——"
        case .resumed:
            return "—— 繼續 ——"
        case .gap(let gap):
            if gap.isInterruption {
                return TranscriptInterruption(at: gap.from.seconds, reason: gap.reason, lostSeconds: gap.lostSeconds).label
            }
            return "〔\(TranscriptInterruption.describe(lostSeconds: gap.duration))沒有字幕：\(describe(gap.reason))〕"
        }
    }

    private static func describe(_ reason: GapReason) -> String {
        switch reason {
        case .network: "網路中斷"
        case .backpressure: "辨識跟不上"
        case .engineStopped: "辨識停止"
        case .sleep, .deviceLost, .outputChanged, .captureStalled, .unknown: "原因不明"
        }
    }

    /// 換行換成空白、每一行前後的空白去掉：一筆只占一行，agent 一行一行讀不會讀錯。
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func header(title: String, startedAt: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        let stamp =
            "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2)) "
            + "\(padded(parts.hour, 2)):\(padded(parts.minute, 2))"
        let name = oneLine(title)
        let first = name.isEmpty ? "# ThunderFlow 即時逐字稿｜\(stamp) 開始" : "# ThunderFlow 即時逐字稿｜\(name)｜\(stamp) 開始"
        return "\(first)\n# 英文由語音自動辨識，可能有錯字；⚑ 是使用者標記的重點\n"
    }

    /// 時:分:秒。
    private static func clockTime(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return "\(padded(parts.hour, 2)):\(padded(parts.minute, 2)):\(padded(parts.second, 2))"
    }

    private static func padded(_ value: Int?, _ width: Int) -> String {
        let digits = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func write(_ text: String, to descriptor: Int32, path: String) throws {
        try Array(text.utf8).withUnsafeBytes { try FileIO.writeAll($0, to: descriptor, path: path) }
    }
}
