import Foundation
import ThunderCore

/// OpenAI 的 Responses API（串流）。即時翻譯、精修中文、摘要共用。
///
/// API Key 只放在記憶體裡，隨請求的 `Authorization` 標頭送出；不寫進任何檔案或 log，
/// 錯誤訊息裡如果出現也會被遮掉。只連到 `baseURL`。
public struct OpenAITextModel: TextModel {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    /// - Parameter baseURL: API 的根網址，預設是 `https://api.openai.com/v1`。
    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func stream(_ request: TextRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 請求的內容（JSON）。公開出來是為了測試：不用連網路就能檢查送出去的是什麼。
    public static func body(for request: TextRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "instructions": request.instructions,
            "input": request.input,
            "stream": true,
        ]
        if let limit = request.maxOutputTokens { body["max_output_tokens"] = limit }
        if let effort = request.reasoningEffort { body["reasoning"] = ["effort": effort] }
        if let schema = request.schema {
            guard let object = try? JSONSerialization.jsonObject(with: Data(schema.json.utf8)) as? [String: Any] else {
                throw TextModelError.invalidResponse("結構化輸出的 schema 不是合法的 JSON 物件")
            }
            body["text"] = ["format": ["type": "json_schema", "name": schema.name, "schema": object, "strict": true]]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// 解析串流裡的一行。回傳這一行帶來的輸出文字（沒有就是 nil）；遇到錯誤事件就丟出錯誤。
    public static func outputText(fromLine line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
            let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            let type = event["type"] as? String
        else { return nil }
        switch type {
        case "response.output_text.delta":
            return event["delta"] as? String
        case "error":
            let detail = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? payload
            throw TextModelError.invalidResponse(detail)
        case "response.failed", "response.incomplete":
            let response = event["response"] as? [String: Any]
            let detail =
                (response?["error"] as? [String: Any])?["message"] as? String
                ?? (response?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? type
            throw TextModelError.invalidResponse(detail)
        default:
            return nil
        }
    }

    private func run(_ request: TextRequest, yield: (String) -> Void) async throws {
        guard !apiKey.isEmpty else { throw TextModelError.missingCredential }
        var http = URLRequest(url: baseURL.appendingPathComponent("responses"))
        http.httpMethod = "POST"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try Self.body(for: request)
        http.timeoutInterval = 120

        let (bytes, response) = try await session.bytes(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 錯誤內容通常是一小段 JSON；最多讀 2 KB
            var raw = Data()
            for try await byte in bytes {
                raw.append(byte)
                if raw.count >= 2_048 { break }
            }
            throw TextModelError.http(status: status, message: redacted(Self.errorMessage(from: raw)))
        }
        for try await line in bytes.lines {
            do {
                if let text = try Self.outputText(fromLine: line), !text.isEmpty { yield(text) }
            } catch let error as TextModelError {
                if case .invalidResponse(let detail) = error { throw TextModelError.invalidResponse(redacted(detail)) }
                throw error
            }
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any], let message = error["message"] as? String
        {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// 服務的錯誤訊息有時會帶出 Key 的片段；一律遮掉。
    private func redacted(_ text: String) -> String {
        var result = text.replacingOccurrences(of: apiKey, with: "[key]")
        if let pattern = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_\\-*]{6,}") {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[key]")
        }
        return result
    }
}
