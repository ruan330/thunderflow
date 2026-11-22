import Testing
import ThunderUI

/// 加速翻譯（OpenAI 的 Fast mode，HANDOVER.md P11）：翻譯的單價約 2 倍，轉錄不變。
@Suite("預估費用：加速翻譯")
struct EstimatedCostFastTests {
    @Test("開了加速翻譯：翻譯的部分約 2 倍，轉錄不變；沒有開時和原本一樣")
    func doublesTranslation() {
        let normal = EstimatedCost(audioSeconds: 3_600, billedSeconds: nil, provisional: true)
        let fast = EstimatedCost(audioSeconds: 3_600, billedSeconds: nil, provisional: true, fastTranslation: true)
        #expect(abs(normal.dollars - (1.02 + 0.27)) < 0.000_1)
        #expect(abs(fast.dollars - (1.02 + 0.54)) < 0.000_1)
        let off = EstimatedCost(audioSeconds: 3_600, billedSeconds: 1_800, provisional: false, fastTranslation: true)
        #expect(abs(off.dollars - (0.51 + 0.08)) < 0.000_1, "照計費秒數算；不開暫定譯文時翻譯每小時 0.08 的 2 倍")
    }
}
