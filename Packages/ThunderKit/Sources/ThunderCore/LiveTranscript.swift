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
    /// 一段英文確定了（`segment` 是段號）。同一段之後可能再確定一次（補上晚到的字或標點），以最後一次為準。
    case speech(String, segment: Int?)
    /// 這一段開始有字了，而且前一段確定不會再補字：前一段可以寫出去。
    case speaking(segment: Int?)
    /// 這一段新增的字（增量）。晚到的尾巴（最多 2 個字）會先以下一段的增量送出、之後併回上一段，
    /// 所以要看下一段累積了幾個字，才知道上一段是不是確定了。
    case words(String, segment: Int?)
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
/// 一段英文要等它真的確定了才寫：真的引擎常在一段確定之後 0.2–0.8 秒再確定一次、補上最後一兩個字，
/// 所以先放著、以最後一次為準。補上的字原本是以下一段的增量送出的（切段的「晚到的尾巴」，最多 2 個字），
/// 所以這些情況才寫出去：下一段確定了；下一段已經超過 2 個字；這一段併入過尾巴之後下一段又有字；
/// `settleDelay` 內沒有變化；或關檔。它還沒寫出去時發生的標記等跟在它後面，照發生的順序寫。
///
/// 每一行前面是發生當下的時刻（不是音訊時間：暫停前後才對得上牆上的時鐘）；一段英文用第一次確定的時刻。
/// 一行用一次 write(2) 寫出。寫入失敗不丟出錯誤：這個檔只是給 agent 讀的副本，不能影響錄音。資料來源永遠是日誌。
public final class LiveTranscriptWriter: Sendable {
    private struct Line {
        var time: Date
        var text: String
    }

    private struct State {
        /// 檔案描述子；關檔之後是 -1。
        var descriptor: Int32
        /// 最後寫出去的段號。段號只增不減，已經寫出去的段（或更早的段）再確定一次就不再寫。
        var lastSegment: Int?
        /// 還沒寫出去的那一段的段號。有的時候，`pending` 的第一行就是它，後面是之後發生的標記等。
        var pendingSegment: Int?
        var pending: [Line] = []
        /// 還沒寫出去的那一段併入過晚到的尾巴（再確定時字變多了）：之後不會再併，下一段一有字它就確定了。
        var pendingExtended = false
        /// 那一段最後一次確定之後，下一段累積的增量（判斷是不是晚到的尾巴）。
        var nextText = ""
        /// 每次重新計時加一：計時到了，只有還是最後一次計時才寫出去。
        var generation = 0
    }

    private let state: Mutex<State>
    private let path: String
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private let settleDelay: Duration

    /// 建立檔案（已經存在就從頭寫）並寫入兩行說明。
    ///
    /// - Parameters:
    ///   - title: 場次的標題（空的就不寫）。
    ///   - startedAt: 開始的時間，寫在說明裡。
    ///   - timeZone: 時刻用的時區。
    ///   - settleDelay: 一段確定之後，這麼久沒有變化就寫出去。要比切段併回尾巴的時限（1.5 秒）長。
    ///   - clock: 每一行前面的時刻（發生當下）。
    public init(
        url: URL, title: String, startedAt: Date, timeZone: TimeZone = .current, settleDelay: Duration = .seconds(3),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.clock = clock
        self.settleDelay = settleDelay
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

    /// 記下一筆。關檔之後、沒有內容（只有空白的英文、已經寫出去的段）時什麼都不做。
    public func append(_ entry: LiveTranscriptEntry) {
        let timer = state.withLock { state -> Int? in
            guard state.descriptor >= 0 else { return nil }
            return apply(entry, &state)
        }
        if let timer { settle(after: timer) }
    }

    /// 關檔：先把還沒寫出去的寫出去。重複呼叫不算錯；關檔之後的 `append` 什麼都不做。
    public func close() {
        state.withLock { state in
            guard state.descriptor >= 0 else { return }
            flush(&state)
            Darwin.close(state.descriptor)
            state.descriptor = -1
        }
    }

    // MARK: 內容

    /// 處理一筆。回傳要重新計時的編號（一段剛確定或補上字的時候），其他是 nil。
    private func apply(_ entry: LiveTranscriptEntry, _ state: inout State) -> Int? {
        switch entry {
        case .speech(let text, let segment):
            let line = Self.oneLine(text)
            guard !line.isEmpty else { return nil }
            guard let segment else {
                // 不分段的引擎：沒有「再確定一次」，直接寫
                flush(&state)
                write(Line(time: clock(), text: line), &state)
                return nil
            }
            if let last = state.lastSegment, segment <= last { return nil }
            if let pending = state.pendingSegment {
                if segment < pending { return nil }
                if segment == pending {
                    // 同一段再確定一次（補上最後的字或標點）：以這一次為準，時間維持第一次確定的時刻。
                    // 字變多了就是併入了晚到的尾巴；下一段重新從空的開始
                    if Self.wordCount(line) > Self.wordCount(state.pending[0].text) { state.pendingExtended = true }
                    state.nextText = ""
                    state.pending[0].text = line
                    state.generation += 1
                    return state.generation
                }
                flush(&state)
            }
            state.pendingSegment = segment
            state.pending = [Line(time: clock(), text: line)]
            state.generation += 1
            return state.generation
        case .speaking(let segment):
            // 下一段開始有字了：前一段不會再補字
            if let segment, let pending = state.pendingSegment, segment > pending { flush(&state) }
            return nil
        case .words(let text, let segment):
            guard let segment, let pending = state.pendingSegment, segment > pending else { return nil }
            state.nextText += text
            // 超過尾巴的字數就不可能再併回去；已經併過一次也不會再併
            if state.pendingExtended || Self.wordCount(state.nextText) > Self.maximumLateTailWords { flush(&state) }
            return nil
        case .marker, .paused, .resumed, .gap:
            guard let text = Self.text(for: entry) else { return nil }
            let line = Line(time: clock(), text: text)
            if state.pending.isEmpty {
                write(line, &state)
            } else {
                state.pending.append(line)
            }
            return nil
        }
    }

    /// `settleDelay` 之後，如果這段期間沒有再變（還是這一次計時），就寫出去。
    private func settle(after timer: Int) {
        let delay = settleDelay.components
        let seconds = Double(delay.seconds) + Double(delay.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            state.withLock { state in
                guard state.descriptor >= 0, state.generation == timer else { return }
                flush(&state)
            }
        }
    }

    /// 把還沒寫出去的照順序寫出去。
    private func flush(_ state: inout State) {
        for line in state.pending { write(line, &state) }
        if let segment = state.pendingSegment { state.lastSegment = segment }
        state.pending = []
        state.pendingSegment = nil
        state.pendingExtended = false
        state.nextText = ""
    }

    /// 切段併回上一段的「晚到的尾巴」最多幾個字（`Segmenter.Configuration.lateTailWords`）。
    private static let maximumLateTailWords = 2.0

    /// 字數，算法和切段相同：以空白分開、含有字母或數字的算一個字；中文字每 2 個算一個字。
    private static func wordCount(_ text: String) -> Double {
        var count = 0.0
        for token in text.split(whereSeparator: \.isWhitespace) {
            var ideographs = 0
            var hasLetterOrDigit = false
            for scalar in token.unicodeScalars {
                if scalar.properties.isIdeographic {
                    ideographs += 1
                } else if CharacterSet.alphanumerics.contains(scalar) {
                    hasLetterOrDigit = true
                }
            }
            count += Double(ideographs) / 2 + (hasLetterOrDigit ? 1 : 0)
        }
        return count
    }

    private func write(_ line: Line, _ state: inout State) {
        guard state.descriptor >= 0 else { return }
        try? Self.write("[\(Self.clockTime(line.time, calendar: calendar))] \(line.text)\n", to: state.descriptor, path: path)
    }

    /// 標記、暫停、繼續、缺口的那一行。
    private static func text(for entry: LiveTranscriptEntry) -> String? {
        switch entry {
        case .speech, .speaking, .words:
            return nil
        case .marker:
            return "⚑ 標記"
        case .paused:
            return "—— 暫停 ——"
        case .resumed:
            return "—— 繼續 ——"
        case .gap(let gap):
            if gap.isInterruption {
                return TranscriptInterruption(
                    at: gap.from.seconds, reason: gap.reason, lostSeconds: gap.lostSeconds, source: gap.source
                ).label
            }
            return "〔\(TranscriptInterruption.describe(lostSeconds: gap.duration))沒有字幕：\(describe(gap.reason))〕"
        }
    }

    private static func describe(_ reason: GapReason) -> String {
        switch reason {
        case .network: "網路中斷"
        case .backpressure: "辨識跟不上"
        case .engineStopped: "辨識停止"
        case .sleep, .deviceLost, .outputChanged, .captureStalled, .sourceChanged, .unknown: "原因不明"
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
