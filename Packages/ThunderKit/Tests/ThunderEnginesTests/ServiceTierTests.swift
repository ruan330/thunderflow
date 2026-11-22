import Foundation
import Testing
import ThunderCore
import ThunderEngines

/// 優先處理（OpenAI 的 `service_tier`，DESIGN.md 5.6.2 節）：每個請求快約 0.14 秒，單價較高，預設不用。
@Suite("翻譯請求：優先處理")
struct ServiceTierTests {
    private func body(_ request: TextRequest) throws -> [String: Any] {
        let data = try OpenAITextModel.body(for: request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("指定優先處理時，請求帶上 service_tier；沒有指定就不帶")
    func requestBody() throws {
        let plain = TextRequest(model: "gpt-6-luna", instructions: "翻譯", input: "Hello")
        #expect(try body(plain)["service_tier"] == nil)
        let fast = TextRequest(model: "gpt-6-luna", instructions: "翻譯", input: "Hello", serviceTier: "priority")
        #expect(try body(fast)["service_tier"] as? String == "priority")
    }

    @Test("翻譯排程設定了優先處理：段的定稿、整句定稿、暫定譯文的請求都帶上")
    func plannerPassesTier() {
        var configuration = TranslationPlanner.Configuration()
        configuration.sentences = true
        configuration.provisional = true
        configuration.sentenceProvisional = true
        configuration.serviceTier = "priority"
        var planner = TranslationPlanner(configuration: configuration)
        var effects = planner.pendingText("One two three four", segment: 0, at: 0)
        effects += planner.segmentFinished(0, text: "One two three four.", reason: .sentenceEnd, at: 0.5)
        let requests = effects.compactMap { if case .start(_, let content) = $0 { content } else { nil } }
        #expect(requests.count == 3, "暫定譯文、段的定稿、整句定稿")
        #expect(requests.allSatisfy { $0.serviceTier == "priority" })

        var plain = TranslationPlanner(configuration: TranslationPlanner.Configuration())
        let segment = plain.segmentFinished(0, text: "Hello.", reason: .sentenceEnd, at: 0)
        #expect(segment.allSatisfy { if case .start(_, let content) = $0 { content.serviceTier == nil } else { true } })
    }
}
