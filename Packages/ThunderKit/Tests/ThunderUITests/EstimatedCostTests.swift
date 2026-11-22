import Testing
import ThunderUI

@Suite("預估費用：轉錄照計費秒數，翻譯照這一場開始時的暫定譯文設定")
struct EstimatedCostTests {
    /// 美元相差不到百萬分之一就算相等。
    private func expectDollars(_ cost: EstimatedCost, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(cost.dollars - expected) < 0.000_001, "實際是 \(cost.dollars)", sourceLocation: sourceLocation)
    }

    @Test("引擎回報了計費秒數：照計費秒數算，不照錄下的長度（例如翻譯斷線、沒有送去轉錄的那段不算）")
    func billedSecondsWin() {
        // 錄了 1 小時，送去轉錄 30 分鐘：轉錄 30 × 0.017 = 0.51，翻譯半小時 0.04
        expectDollars(EstimatedCost(audioSeconds: 3_600, billedSeconds: 1_800, provisional: false), 0.55)
        // 開了暫定譯文：翻譯半小時 0.135
        expectDollars(EstimatedCost(audioSeconds: 3_600, billedSeconds: 1_800, provisional: true), 0.645)
    }

    @Test("引擎還沒回報計費秒數（剛開始的幾秒）：照錄下的長度估計")
    func fallsBackToAudioSeconds() {
        // 1 小時：轉錄 60 × 0.017 = 1.02，翻譯 0.08 或 0.27
        expectDollars(EstimatedCost(audioSeconds: 3_600, billedSeconds: nil, provisional: false), 1.10)
        expectDollars(EstimatedCost(audioSeconds: 3_600, billedSeconds: nil, provisional: true), 1.29)
    }

    @Test("引擎回報計費 0 秒（還沒送出任何音訊就停了）：沒有費用")
    func nothingBilled() {
        expectDollars(EstimatedCost(audioSeconds: 600, billedSeconds: 0, provisional: true), 0)
    }

    @Test("開了暫定譯文：翻譯每小時 0.27 美元；沒開：0.08 美元；轉錄都是每分鐘 0.017 美元")
    func rates() {
        #expect(EstimatedCost.transcriptionPerMinute == 0.017)
        #expect(EstimatedCost.translationPerHour == 0.08)
        #expect(EstimatedCost.translationPerHourWithProvisional == 0.27)
        let with = EstimatedCost(audioSeconds: 0, billedSeconds: 3_600, provisional: true)
        let without = EstimatedCost(audioSeconds: 0, billedSeconds: 3_600, provisional: false)
        expectDollars(with, 1.29)
        expectDollars(without, 1.10)
    }

    @Test("顯示成「約 $1.29」：小數兩位")
    func text() {
        #expect(EstimatedCost(audioSeconds: 0, billedSeconds: 3_600, provisional: true).text == "約 $1.29")
        #expect(EstimatedCost(audioSeconds: 0, billedSeconds: nil, provisional: false).text == "約 $0.00")
    }
}
