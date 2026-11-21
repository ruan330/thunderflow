import Foundation

extension SessionMeta {
    /// 沒有標題的場次顯示成這個名稱。
    public static let untitledTitle = "未命名"

    /// 給人看的標題：去掉頭尾的空白並收成一行；沒有標題時是「未命名」。
    public var displayTitle: String {
        let title = TextFlow.singleLine(self.title)
        return title.isEmpty ? Self.untitledTitle : title
    }
}

/// `transcript.md` 與 `summary.md` 開頭共用的兩行：標題與資訊列。
enum SessionHeader {
    /// 標題一行、資訊列一行，各以換行結尾。
    ///
    /// 資訊列是開始時間（`timeZone` 的當地時間，`2026-12-02 10:30`）、錄音長度與音訊來源，以「 · 」分隔；
    /// 沒有來源說明時省略那一項。
    static func render(title: String, meta: SessionMeta, timeZone: TimeZone) -> String {
        var items = [dateTime(meta.startedAt, timeZone: timeZone), Timecode.duration(meta.durationSeconds)]
        let source = TextFlow.singleLine(meta.source)
        if !source.isEmpty { items.append(source) }
        return "# \(title)\n\(items.joined(separator: " · "))\n"
    }

    /// 當地時間，寫法固定（不隨系統的語言與地區設定改變）：`2026-12-02 10:30`。
    private static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2)) "
            + "\(padded(parts.hour, 2)):\(padded(parts.minute, 2))"
    }
}
