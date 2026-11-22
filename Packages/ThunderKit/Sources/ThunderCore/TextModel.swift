import Foundation

/// 給文字模型的一次請求。即時翻譯、精修中文、摘要都用它。
public struct TextRequest: Sendable, Equatable {
    /// 模型 ID，例如 `gpt-6-luna`。模型放在設定裡，不寫死（DESIGN.md 決策 D24）。
    public var model: String
    /// 系統提示：模型要扮演的角色與規則。
    public var instructions: String
    /// 這一次要處理的內容。
    public var input: String
    /// 輸出的 token 上限；nil 表示不限制。
    public var maxOutputTokens: Int?
    /// 推理的程度（例如 `none`）。即時翻譯要快，所以用 `none`；nil 表示不指定。
    public var reasoningEffort: String?
    /// 要求模型照這份 JSON Schema 輸出（結構化輸出）；nil 表示一般文字。
    public var schema: TextSchema?
    /// OpenAI 的處理等級（例如 `priority`：較快、單價較高）；nil 表示預設。
    public var serviceTier: String?

    public init(
        model: String,
        instructions: String,
        input: String,
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = "none",
        schema: TextSchema? = nil,
        serviceTier: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.schema = schema
        self.serviceTier = serviceTier
    }
}

/// 結構化輸出的格式：一個名稱，加上 JSON Schema 的原文。
public struct TextSchema: Sendable, Equatable {
    public var name: String
    /// JSON Schema（一個 JSON 物件的原文）。
    public var json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

public enum TextModelError: Error, Equatable, CustomStringConvertible {
    /// 沒有 API Key。
    case missingCredential
    /// 服務回了錯誤的狀態碼。`message` 是服務給的說明（不含憑證）。
    case http(status: Int, message: String)
    /// 回應的格式看不懂。
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .missingCredential: "沒有設定 API Key"
        case .http(let status, let message): "文字模型回應 HTTP \(status)：\(message)"
        case .invalidResponse(let detail): "文字模型的回應看不懂：\(detail)"
        }
    }

    /// 這個錯誤是不是暫時性的（請求過多、服務端錯誤），值得稍後再試。
    public var isTransient: Bool {
        if case .http(let status, _) = self { return status == 429 || status >= 500 }
        return false
    }
}

/// 文字模型：送出一次請求，以串流取回輸出的文字。
///
/// 對外可以替換的四個接口之一（DESIGN.md 9.3 節）：正式環境是 OpenAI 的 Responses API，
/// 測試時換成照劇本回答的假模型。
///
/// 約定：
/// - 回傳的串流依序送出輸出文字的片段，全部接起來就是完整的輸出。
/// - 請求失敗時串流以錯誤結束；已經送出的片段不保證完整。
/// - 串流被取消（不再有人讀）時，實作必須盡快中止請求。
public protocol TextModel: Sendable {
    func stream(_ request: TextRequest) -> AsyncThrowingStream<String, any Error>
}

extension TextModel {
    /// 送出請求並等完整的輸出。
    public func complete(_ request: TextRequest) async throws -> String {
        var output = ""
        for try await piece in stream(request) { output += piece }
        return output
    }
}
