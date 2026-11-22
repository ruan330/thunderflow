import Foundation
import Testing
import ThunderCore
import ThunderEngines

/// 整句定稿的提示（DESIGN.md 5.6.2 節；HANDOVER.md P11 的盲測：加上這一條之後，裁判模型 2 比 1 偏好）。
@Suite("翻譯排程：整句定稿的提示")
struct SentencePromptTests {
    @Test("整句定稿要求不加入原文沒有的資訊；簡體字重試時仍然有這一條")
    func faithful() throws {
        var configuration = TranslationPlanner.Configuration()
        configuration.sentences = true
        configuration.provisional = false
        var planner = TranslationPlanner(configuration: configuration)
        let effects = planner.segmentFinished(0, text: "So you can turn the chatbot into a hacker.", reason: .sentenceEnd, at: 0)
        let requests = effects.compactMap { if case .start(let id, let content) = $0 { (id, content) } else { nil } }
        let sentence = try #require(requests.first { $0.1.input.contains("這一句：") })
        #expect(sentence.1.instructions.contains("不要加入原文沒有的資訊"))

        // 簡體字重試：同一條規則還在
        let retry = planner.completed(request: sentence.0, text: "所以你可以把聊天机器人变成黑客。", at: 0.8)
        let strict = try #require(retry.compactMap { if case .start(_, let content) = $0 { content } else { nil } }.first)
        #expect(strict.instructions.contains("不要加入原文沒有的資訊"))
        #expect(strict.instructions.contains("只能使用繁體字"))
    }
}
