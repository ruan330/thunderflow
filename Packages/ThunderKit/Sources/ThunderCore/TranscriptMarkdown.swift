import Foundation

/// 把段落排成 `transcript.md`（DESIGN.md 5.9 節）。
///
///     # Building Agents with Bedrock
///     2026-12-02 10:30 · 58:12 · 系統音訊
///
///     ### 00:00:12
///     So today we're going to talk about building production-ready agents...
///
///     今天我們要談的是如何打造可以上線的 Agent……
///
///     ### 00:01:35 ⚑
///     …
///
/// - 第一行是標題，沒有標題時是「未命名」。
/// - 第二行是開始時間（`timeZone` 的當地時間）、錄音長度與音訊來源，以「 · 」分隔；沒有來源說明時省略那一項。
/// - 每個段落是一個 `### HH:MM:SS` 的小標題（有重點標記時後面加上「 ⚑」）、英文、空一行、中文；
///   沒有中文的段落只有英文。段落之間空一行。
/// - 檔案以一個換行結尾；沒有任何段落時只有前兩行。
public enum TranscriptMarkdown {
    public static func render(meta: SessionMeta, blocks: [TranscriptBlock], timeZone: TimeZone = .current) -> String {
        var text = SessionHeader.render(title: meta.displayTitle, meta: meta, timeZone: timeZone)
        for block in blocks {
            text += "\n### \(Timecode.clock(block.start))\(block.marked ? " ⚑" : "")\n\(block.en)\n"
            if !block.zh.isEmpty { text += "\n\(block.zh)\n" }
        }
        return text
    }
}
