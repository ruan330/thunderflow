import Foundation
import Testing
import ThunderCore
import ThunderTestKit
import ThunderUI

/// 效能預算：字幕區的增量更新。錄得越久，每一次更新字幕區的成本不能跟著變高（DESIGN.md 9.8 節）。
///
/// `CaptionModelPerfTests` 量的是畫面狀態（`LiveCaptionModel`）；這裡再加上兩區字幕算出要改哪些段落
/// （`CaptionZoneSync.update`）。每一次都整份比對的話，第 8 小時（7,200 行）會比第 1 分鐘慢幾十倍。
@MainActor
@Suite(
    "效能預算 Perf：字幕區的增量更新",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct CaptionZoneSyncPerfTests {
    /// 一段的事件：12 個英文字、一次暫定譯文、英文確定、中文定稿。
    private static func events(for segment: Int) -> [CaptionEvent] {
        var events = (0..<12).map {
            CaptionEvent.source(CaptionText(text: " word\($0)", kind: .delta, at: .zero, segment: segment))
        }
        events.append(.provisional(CaptionText(text: "暫定譯文", kind: .delta, at: .zero, segment: segment)))
        events.append(.source(CaptionText(text: "twelve words in this segment", kind: .segmentEnd, at: .zero, segment: segment)))
        events.append(.translation(CaptionText(text: "這一段的中文定稿", kind: .segmentEnd, at: .zero, segment: segment)))
        return events
    }

    @Test("中文與英文兩區：第 8 小時每一次更新的成本（每個事件都更新一次），不超過第 1 分鐘的預算倍數")
    func updateCostDoesNotGrow() throws {
        let budgets = try PerfBudgets.load()
        let model = LiveCaptionModel()
        let chinese = CaptionZoneOptions(language: .chinese, showsProvisional: true, showsFlags: true)
        let english = CaptionZoneOptions(language: .english, showsProvisional: true, showsFlags: false)
        var chineseZone = CaptionZoneSync()
        var englishZone = CaptionZoneSync()
        var marked: Set<Int> = []

        func update() {
            _ = chineseZone.update(board: model.board, marked: marked, options: chinese)
            _ = englishZone.update(board: model.board, marked: marked, options: english)
        }
        /// 計時：每個事件送進來之後立刻更新畫面狀態與兩區字幕（最壞的情況）。每 50 段標記一次重點。
        func play(_ range: Range<Int>) -> Duration {
            let clock = ContinuousClock()
            let started = clock.now
            for segment in range {
                for event in Self.events(for: segment) {
                    model.receive(event)
                    model.flush()
                    update()
                }
                if segment % 50 == 0, let last = model.board.lines.last { marked.insert(last.id) }
            }
            return clock.now - started
        }
        /// 不計時，快速補到某一段：每 10 段才更新一次。
        func fill(_ range: Range<Int>) {
            for segment in range {
                for event in Self.events(for: segment) { model.receive(event) }
                if segment % 10 == 9 {
                    model.flush()
                    update()
                }
            }
            model.flush()
            update()
        }

        // 每 4 秒一段：第 1 分鐘是 15 段，8 小時是 7,200 段。各量 500 段，比較開頭與結尾
        fill(0..<200)
        let early = play(200..<700)
        fill(700..<6_700)
        let late = play(6_700..<7_200)

        #expect(model.board.lines.count == 7_200)
        #expect(chineseZone.paragraphs.count == 7_200)
        #expect(englishZone.paragraphs.last == CaptionParagraph(text: "twelve words in this segment", kind: .settled, flagged: false))
        let ratio = late.seconds / early.seconds
        let budget = try budgets.maximum("ui.eventCostGrowth.ratio.max")
        print("量測：字幕區增量更新第 8 小時的成本是開頭的 \(ratio) 倍（每個事件 \(late.seconds / 7.5) 毫秒；預算 \(budget) 倍）")
        #expect(ratio <= budget, "開頭 500 段 \(early)、結尾 500 段 \(late)：\(ratio) 倍，預算 \(budget) 倍")
    }
}
