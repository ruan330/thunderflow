import Foundation
import Testing
import ThunderCore
import ThunderUI

private func indicator(_ symbol: IndicatorSymbol, _ tone: IndicatorTone, _ text: String) -> Indicator {
    Indicator(symbol: symbol, tone: tone, text: text)
}

/// 任兩個不同的狀態，符號或文字至少有一個不一樣：不看顏色也分得出來。
private func distinguishableWithoutColor(_ indicators: [Indicator]) -> Bool {
    for (index, first) in indicators.enumerated() {
        for second in indicators[(index + 1)...] where first.symbol == second.symbol && first.text == second.text {
            return false
        }
    }
    return true
}

private func meta(state: SessionState = .complete, recovered: Bool = false, failedSteps: [String] = []) -> SessionMeta {
    SessionMeta(startedAt: Date(timeIntervalSince1970: 1_800_000_000), state: state, recovered: recovered, failedSteps: failedSteps)
}

@Suite("狀態的表示：每個狀態都有自己的符號與文字，不只靠顏色")
struct IndicatorTests {
    @Test("錄音狀態：尚未開始、準備中、錄音中、已暫停、收尾中各有自己的符號、色調與文字")
    func recorder() {
        #expect(Indicator.recorder(.idle) == indicator(.dot, .neutral, "尚未開始"))
        #expect(Indicator.recorder(.starting) == indicator(.spinner, .neutral, "準備中"))
        #expect(Indicator.recorder(.recording) == indicator(.dot, .recording, "錄音中"))
        #expect(Indicator.recorder(.paused) == indicator(.pause, .attention, "已暫停"))
        #expect(Indicator.recorder(.stopping) == indicator(.spinner, .neutral, "收尾中"))
    }

    @Test("翻譯狀態：連線中、即時、重新連線中、待命各有自己的符號、色調與文字；還沒有狀態時當成連線中")
    func engine() {
        let connecting = indicator(.boltOutline, .attention, "翻譯連線中")
        #expect(Indicator.engine(nil) == connecting)
        #expect(Indicator.engine(.connecting) == connecting)
        #expect(Indicator.engine(.live) == indicator(.bolt, .live, "翻譯即時"))
        #expect(Indicator.engine(.reconnecting) == indicator(.boltOutline, .attention, "翻譯重新連線中，錄音持續中"))
        #expect(Indicator.engine(.idle) == indicator(.boltOutline, .neutral, "翻譯待命"))
    }

    @Test("翻譯已停止：劃掉的閃電，文字寫出原因，並說明錄音持續中")
    func engineFailed() {
        #expect(Indicator.engine(.failed(reason: "API Key 無效")) == indicator(.boltSlash, .danger, "翻譯已停止：API Key 無效（錄音持續中）"))
    }

    @Test("每個翻譯狀態的符號或文字都不一樣")
    func engineDistinguishable() {
        let statuses: [EngineStatus] = [.connecting, .live, .reconnecting, .idle, .failed(reason: "網路中斷")]
        #expect(distinguishableWithoutColor(statuses.map { Indicator.engine($0) }))
    }

    @Test("每個錄音狀態的符號或文字都不一樣")
    func recorderDistinguishable() {
        #expect(distinguishableWithoutColor(RecorderPhase.allCases.map { Indicator.recorder($0) }))
    }

    @Test("過去錄音的標籤：正在處理時顯示處理的進度；還沒處理完顯示處理中，優先於失敗與復原")
    func badgeProcessing() {
        #expect(Indicator.sessionBadge(meta(failedSteps: ["summary"]), progress: "產生摘要中") == indicator(.spinner, .neutral, "產生摘要中"))
        #expect(Indicator.sessionBadge(meta(state: .finalizing), progress: "合併錄音中") == indicator(.spinner, .neutral, "合併錄音中"))
        #expect(Indicator.sessionBadge(meta(state: .finalizing)) == indicator(.spinner, .neutral, "處理中"))
        #expect(Indicator.sessionBadge(meta(state: .finalizing, recovered: true, failedSteps: ["summary"])) == indicator(.spinner, .neutral, "處理中"))
    }

    @Test("過去錄音的標籤：摘要失敗；其他步驟失敗顯示部分處理失敗；失敗優先於已復原")
    func badgeFailed() {
        let summaryFailed = indicator(.warning, .danger, "摘要失敗")
        let partlyFailed = indicator(.warning, .danger, "部分處理失敗")
        #expect(Indicator.sessionBadge(meta(failedSteps: ["summary"])) == summaryFailed)
        #expect(Indicator.sessionBadge(meta(failedSteps: ["audio", "summary"])) == summaryFailed)
        #expect(Indicator.sessionBadge(meta(failedSteps: ["audio"])) == partlyFailed)
        #expect(Indicator.sessionBadge(meta(recovered: true, failedSteps: ["summary"])) == summaryFailed)
        #expect(Indicator.sessionBadge(meta(recovered: true, failedSteps: ["audio"])) == partlyFailed)
    }

    @Test("過去錄音的標籤：從異常結束中復原的場次顯示已復原；正常完成的不顯示標籤")
    func badgeRecoveredOrNone() {
        #expect(Indicator.sessionBadge(meta(recovered: true)) == indicator(.recovered, .attention, "已復原"))
        #expect(Indicator.sessionBadge(meta()) == nil)
    }
}
