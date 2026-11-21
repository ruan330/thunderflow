import Foundation
import Observation
import Synchronization
import ThunderCore

/// 即時字幕的畫面狀態。引擎的事件可以從任何執行緒送進來（`receive`），畫面在主執行緒上讀。
///
/// 事件先放進佇列，合併之後才更新畫面：每秒最多更新 30 次，沒有事件時不留任何計時器
/// （DESIGN.md 9.8 節：閒置時沒有定時喚醒）。
@MainActor
@Observable
public final class LiveCaptionModel {
    public private(set) var board = CaptionBoard()
    public private(set) var engineStatus: EngineStatus?
    /// 引擎回報的累計計費秒數。
    public private(set) var billedSeconds: Double = 0
    /// 引擎回報的缺口合計（秒）：這些音訊沒有字幕。
    public private(set) var gapSeconds: Double = 0
    /// 畫面更新了幾次。給測試確認「合併更新」用。
    public private(set) var updateCount = 0

    /// 兩次更新之間最短的間隔。
    public static let minimumInterval: Duration = .milliseconds(33)

    @ObservationIgnored private let inbox = Inbox()

    public init() {}

    /// 引擎送來一個事件。可以從任何執行緒呼叫，立即返回。
    nonisolated public func receive(_ event: CaptionEvent) {
        guard inbox.push(event) else { return }
        // 佇列原本是空的：排一次更新。之後進來的事件會在同一次更新裡一起處理。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.minimumInterval)
            self?.flush()
        }
    }

    /// 引擎結束了（場次停止）。
    public func engineEnded() {
        flush()
        board.engineEnded()
        updateCount += 1
    }

    /// 清空，準備下一場。
    public func reset() {
        _ = inbox.drain()
        board = CaptionBoard()
        engineStatus = nil
        billedSeconds = 0
        gapSeconds = 0
    }

    /// 立刻套用佇列裡的事件。
    ///
    /// 字幕直接在原處更新：一場長的錄音有幾千行，每次更新都複製一份再比較，成本會隨場次變長
    /// （DESIGN.md 9.8 節：第 8 小時每個事件的處理成本不超過第 1 分鐘的 1.5 倍）。
    /// 畫面也要配合：只拿最後幾行出來畫，不要一直拿著整份字幕，否則下一次更新還是會整份複製。
    public func flush() {
        let events = inbox.drain()
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .status(let status): engineStatus = status
            case .usage(let seconds): billedSeconds = seconds
            case .gap(let gap): gapSeconds += gap.duration
            default: board.apply(event)
            }
        }
        updateCount += 1
    }
}

/// 等著被畫面處理的事件。
private final class Inbox: Sendable {
    private let events = Mutex<[CaptionEvent]>([])

    /// 放進一個事件。回傳 true 表示佇列原本是空的（需要排一次更新）。
    func push(_ event: CaptionEvent) -> Bool {
        events.withLock { events in
            events.append(event)
            return events.count == 1
        }
    }

    func drain() -> [CaptionEvent] {
        events.withLock { events in
            defer { events.removeAll(keepingCapacity: true) }
            return events
        }
    }
}
