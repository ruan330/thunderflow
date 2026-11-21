import Foundation
import ThunderCore

// 尚未實作：這個提交只有介面，讓測試可以編譯、執行並失敗。實作在下一個提交。
public struct OpenAITextModel: TextModel {
    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {}

    public func stream(_ request: TextRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public static func body(for request: TextRequest) throws -> Data { Data("{}".utf8) }
    public static func outputText(fromLine line: String) throws -> String? { nil }
}
