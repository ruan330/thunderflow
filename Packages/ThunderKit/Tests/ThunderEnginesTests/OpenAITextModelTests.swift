import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 攔下 `URLSession` 的請求，回傳事先準備好的回應。不會真的連到網路。
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status = 200
        var body = Data()
    }

    static let stub = LockedValue(Stub())
    static let requests = LockedValue<[URLRequest]>([])
    static let bodies = LockedValue<[Data]>([])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withValue { $0.append(request) }
        // 經過 URLSession 之後，請求的內容在 httpBodyStream 裡
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.bodies.withValue { $0.append(body) }
        let stub = Self.stub.value
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// 這一組測試共用同一個攔截器，所以一次跑一個。
@Suite("文字模型呼叫：OpenAI Responses API", .serialized)
struct OpenAITextModelTests {
    private static let fakeKey = "sk-test-FAKEKEY-0123456789abcdef"

    private func sse(_ events: [String]) -> Data {
        Data(events.map { "event: message\ndata: \($0)\n\n" }.joined().utf8)
    }

    private func prepare(status: Int = 200, body: Data) {
        StubProtocol.stub.withValue { $0 = .init(status: status, body: body) }
        StubProtocol.requests.withValue { $0 = [] }
        StubProtocol.bodies.withValue { $0 = [] }
    }

    private func model(baseURL: String = "https://api.openai.com/v1") -> OpenAITextModel {
        OpenAITextModel(apiKey: Self.fakeKey, baseURL: URL(string: baseURL)!, session: StubProtocol.session())
    }

    @Test("請求的內容：模型、提示、輸入、串流、推理程度、輸出上限")
    func body() throws {
        let request = TextRequest(
            model: "gpt-6-luna", instructions: "翻成台灣繁體中文", input: "Hello", maxOutputTokens: 400, reasoningEffort: "none")
        let body = try jsonObject(String(decoding: try OpenAITextModel.body(for: request), as: UTF8.self))
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["instructions"] as? String == "翻成台灣繁體中文")
        #expect(body["input"] as? String == "Hello")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] as? Int == 400)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect(body["text"] == nil)
    }

    @Test("結構化輸出：帶上 JSON Schema，並要求嚴格遵守；schema 不是合法的 JSON 會被擋下")
    func structuredOutput() throws {
        var request = TextRequest(model: "gpt-6-luna", instructions: "摘要", input: "…", reasoningEffort: nil)
        request.schema = TextSchema(name: "summary", json: #"{"type":"object","properties":{"title":{"type":"string"}}}"#)
        let body = try jsonObject(String(decoding: try OpenAITextModel.body(for: request), as: UTF8.self))
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "summary")
        #expect(format["strict"] as? Bool == true)
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
        #expect(body["reasoning"] == nil, "沒有指定推理程度就不送這個欄位")
        #expect(body["max_output_tokens"] == nil)

        request.schema = TextSchema(name: "broken", json: "not json")
        #expect(throws: TextModelError.self) { try OpenAITextModel.body(for: request) }
    }

    @Test("串流的每一行：只取輸出文字的增量，其他的事件略過")
    func lines() throws {
        #expect(try OpenAITextModel.outputText(fromLine: #"data: {"type":"response.output_text.delta","delta":"你好"}"#) == "你好")
        #expect(try OpenAITextModel.outputText(fromLine: #"data: {"type":"response.created","response":{}}"#) == nil)
        #expect(try OpenAITextModel.outputText(fromLine: "event: response.output_text.delta") == nil)
        #expect(try OpenAITextModel.outputText(fromLine: "data: [DONE]") == nil)
        #expect(try OpenAITextModel.outputText(fromLine: "") == nil)
        #expect(throws: TextModelError.self) {
            try OpenAITextModel.outputText(fromLine: #"data: {"type":"response.failed","response":{"error":{"message":"boom"}}}"#)
        }
        #expect(throws: TextModelError.self) {
            try OpenAITextModel.outputText(fromLine: #"data: {"type":"error","error":{"message":"boom"}}"#)
        }
    }

    @Test("送到設定的網址，Key 放在 Authorization 標頭；串流的片段依序送出")
    func streams() async throws {
        prepare(body: sse([
            #"{"type":"response.created","response":{}}"#,
            #"{"type":"response.output_text.delta","delta":"今天"}"#,
            #"{"type":"response.output_text.delta","delta":"我想談談"}"#,
            #"{"type":"response.completed","response":{}}"#,
        ]))
        var pieces: [String] = []
        for try await piece in model(baseURL: "https://example.invalid/v1").stream(
            TextRequest(model: "gpt-6-luna", instructions: "翻譯", input: "Today I want to talk"))
        {
            pieces.append(piece)
        }
        #expect(pieces == ["今天", "我想談談"])

        let request = try #require(StubProtocol.requests.value.first)
        #expect(request.url?.absoluteString == "https://example.invalid/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try jsonObject(String(decoding: try #require(StubProtocol.bodies.value.first), as: UTF8.self))
        #expect(sent["input"] as? String == "Today I want to talk")
        #expect(!String(decoding: try #require(StubProtocol.bodies.value.first), as: UTF8.self).contains(Self.fakeKey), "Key 不放在請求的內容裡")
    }

    @Test("服務回錯誤的狀態碼：丟出帶狀態碼與說明的錯誤，而且說明裡不會有 Key", arguments: [401, 429, 500])
    func httpError(status: Int) async throws {
        let message = "Incorrect API key provided: \(Self.fakeKey). You can find your API key at https://platform.openai.com/"
        prepare(status: status, body: Data(#"{"error":{"message":"\#(message)","type":"invalid_request_error"}}"#.utf8))
        do {
            _ = try await model().complete(TextRequest(model: "gpt-6-luna", instructions: "", input: "Hi"))
            Issue.record("應該丟出錯誤")
        } catch let error as TextModelError {
            guard case .http(let code, let detail) = error else {
                Issue.record("應該是 http 錯誤：\(error)")
                return
            }
            #expect(code == status)
            #expect(detail.contains("Incorrect API key"))
            #expect(!detail.contains(Self.fakeKey))
            #expect(!"\(error)".contains("FAKEKEY"))
            #expect(error.isTransient == (status != 401))
        }
    }

    @Test("串流途中出現錯誤事件：以錯誤結束")
    func failsMidStream() async throws {
        prepare(body: sse([
            #"{"type":"response.output_text.delta","delta":"今天"}"#,
            #"{"type":"response.failed","response":{"error":{"message":"server overloaded"}}}"#,
        ]))
        await #expect(throws: TextModelError.self) {
            _ = try await model().complete(TextRequest(model: "gpt-6-luna", instructions: "", input: "Hi"))
        }
    }

    @Test("沒有 Key：不送出任何請求")
    func missingKey() async throws {
        prepare(body: Data())
        let model = OpenAITextModel(apiKey: "", session: StubProtocol.session())
        await #expect(throws: TextModelError.missingCredential) {
            _ = try await model.complete(TextRequest(model: "gpt-6-luna", instructions: "", input: "Hi"))
        }
        #expect(StubProtocol.requests.value.isEmpty)
    }
}
