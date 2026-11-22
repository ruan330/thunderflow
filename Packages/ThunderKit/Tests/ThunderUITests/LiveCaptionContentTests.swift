import Foundation
import Observation
import Synchronization
import Testing
import ThunderCore
import ThunderUI

private func delta(_ text: String, _ segment: Int?) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: .zero, segment: segment))
}

private func ended(_ text: String, _ segment: Int?) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

/// 觀察到改變了沒有（觀察的通知可能從別的執行緒來，所以用鎖）。
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

@MainActor
@Suite("字幕區有沒有內容：畫面只在有與沒有之間切換時重畫")
struct LiveCaptionContentTests {
    @Test("第一個英文字到了才算有字幕；狀態與用量不算；清空（下一場）之後又沒有")
    func appearsAndResets() {
        let model = LiveCaptionModel()
        #expect(!model.hasCaptions)
        model.receive(.status(.connecting))
        model.receive(.usage(audioSeconds: 3))
        model.flush()
        #expect(!model.hasCaptions)

        model.receive(delta(" Hello", 0))
        model.flush()
        #expect(model.hasCaptions)

        model.reset()
        #expect(!model.hasCaptions)

        // 不分段的引擎可能直接送一整句
        model.receive(ended("Hello.", nil))
        model.flush()
        #expect(model.hasCaptions)
    }

    @Test("有字幕之後字幕持續更新：hasCaptions 不再改變，只看它的畫面不會跟著重畫")
    func stableWhileUpdating() {
        let model = LiveCaptionModel()
        model.receive(delta(" Hello", 0))
        model.flush()
        #expect(model.hasCaptions)

        let changed = Flag()
        withObservationTracking {
            _ = model.hasCaptions
        } onChange: {
            changed.set()
        }
        for segment in 0..<50 {
            model.receive(delta(" word", segment))
            model.receive(ended("Segment \(segment).", segment))
            model.flush()
        }
        model.engineEnded()
        #expect(model.board.lines.count == 50)
        #expect(!changed.isSet)
    }
}
