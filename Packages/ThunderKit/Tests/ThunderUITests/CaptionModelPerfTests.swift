import Foundation
import Testing
import ThunderCore
import ThunderTestKit
import ThunderUI

/// 效能預算：即時字幕的畫面狀態。錄得越久，每個事件的處理成本不能跟著變高（DESIGN.md 9.8 節）。
///
/// `CaptionBoardTests` 量的是字幕內容本身（`CaptionBoard.apply`）；這裡量畫面實際走的路徑：
/// 事件送進 `LiveCaptionModel`、合併之後更新畫面狀態。
@MainActor
@Suite(
    "效能預算 Perf：即時字幕的畫面狀態",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized,
    .timeLimit(.minutes(5)))
struct CaptionModelPerfTests {
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

    @Test("LiveCaptionModel：第 8 小時每個事件的處理成本（每個事件都更新一次畫面狀態），不超過第 1 分鐘的預算倍數")
    func eventCostDoesNotGrow() throws {
        let budgets = try PerfBudgets.load()
        let model = LiveCaptionModel()

        /// 計時：每個事件送進來之後立刻更新畫面狀態（最壞的情況；實際上每秒最多更新 30 次）。
        func play(_ range: Range<Int>) -> Duration {
            let clock = ContinuousClock()
            let started = clock.now
            for segment in range {
                for event in Self.events(for: segment) {
                    model.receive(event)
                    model.flush()
                }
            }
            return clock.now - started
        }
        /// 不計時，快速補到某一段：每 10 段才更新一次。
        func fill(_ range: Range<Int>) {
            for segment in range {
                for event in Self.events(for: segment) { model.receive(event) }
                if segment % 10 == 9 { model.flush() }
            }
            model.flush()
        }

        // 每 4 秒一段：第 1 分鐘是 15 段，8 小時是 7,200 段。各量 500 段，比較開頭與結尾
        fill(0..<200)
        let early = play(200..<700)
        fill(700..<6_700)
        let late = play(6_700..<7_200)

        #expect(model.board.lines.count == 7_200)
        #expect(model.board.lines.last?.chinese == "這一段的中文定稿")
        let ratio = late.seconds / early.seconds
        let budget = try budgets.maximum("ui.eventCostGrowth.ratio.max")
        print("量測：字幕畫面狀態第 8 小時的成本是開頭的 \(ratio) 倍（每個事件 \(late.seconds / 7.5) 毫秒；預算 \(budget) 倍）")
        #expect(ratio <= budget, "開頭 500 段 \(early)、結尾 500 段 \(late)：\(ratio) 倍，預算 \(budget) 倍")
    }
}
