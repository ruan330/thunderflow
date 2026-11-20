import Foundation

/// 確認 API Key 可用並列出相關模型。GET /v1/models 不計費。
func checkModels() async throws {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    request.setValue("Bearer \(apiKey())", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 else {
        fail("GET /v1/models 回傳 \(status)：\(redact(String(decoding: data.prefix(300), as: UTF8.self)))")
    }
    struct Listing: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
    let ids = try JSONDecoder().decode(Listing.self, from: data).data.map(\.id).sorted()
    print("API Key 可用，帳號可以存取 \(ids.count) 個模型。")
    for wanted in ["gpt-realtime-translate", "gpt-realtime-whisper", "gpt-live-transcribe", "gpt-transcribe"] {
        print("  \(ids.contains(wanted) ? "✓" : "✗") \(wanted)")
    }
    let audio = ids.filter { $0.contains("realtime") || $0.contains("transcribe") || $0.contains("whisper") || $0.contains("live") }
    print("語音相關：\(audio.joined(separator: ", "))")
    let text = ids.filter { $0.hasPrefix("gpt-") && !audio.contains($0) && !$0.contains("image") && !$0.contains("tts") && !$0.contains("audio") }
    print("文字模型（重翻與摘要的候選）：\(text.joined(separator: ", "))")
}
