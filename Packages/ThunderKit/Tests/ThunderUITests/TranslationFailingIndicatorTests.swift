import Testing
import ThunderCore
import ThunderUI

/// 翻譯連續失敗（DESIGN.md 4.10.4、5.6.2 節）：轉錄照常，但文字模型一直回錯誤（模型名稱不對、Key 沒有權限、額度用完）。
@Suite("狀態列：翻譯連續失敗")
struct TranslationFailingIndicatorTests {
    @Test("翻譯連續失敗：劃掉的閃電、提醒的色調，文字寫出原因，並說明英文字幕與錄音持續中")
    func failing() {
        #expect(
            Indicator.engine(.translationFailing(reason: "文字模型回應 HTTP 404：model not found"))
                == Indicator(symbol: .boltSlash, tone: .attention, text: "翻譯失敗：文字模型回應 HTTP 404：model not found（英文字幕與錄音持續中）"))
    }

    @Test("和其他翻譯狀態的文字都不一樣")
    func distinguishable() {
        let others: [EngineStatus] = [.connecting, .live, .reconnecting, .idle, .failed(reason: "網路中斷")]
        let failing = Indicator.engine(.translationFailing(reason: "網路中斷"))
        #expect(others.allSatisfy { Indicator.engine($0).text != failing.text })
    }
}
