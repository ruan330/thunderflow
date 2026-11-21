import Foundation
import ThunderCore

/// 轉錄連線的設定（DESIGN.md 5.6.2 節的表）。模型與延遲都是設定值，不寫死。
public struct TranscriptionSettings: Sendable, Equatable {
    public var model: String = "gpt-live-transcribe"
    /// `minimal`、`low`、`medium`、`high`、`xhigh`。v1 用 `low`。
    public var delay: String = "low"
    public var languages: [String] = ["en"]
    /// 人名、產品名稱、術語。空白的與重複的會去掉。
    public var keywords: [String] = []
    /// 給轉錄模型的說明（例如場次的標題與講者）。超過 `TranscriptionCommand.promptLimit` 個字元的部分會被截掉。
    public var prompt: String = ""

    public init() {}
}

/// 伺服器送來的事件裡，引擎用得到的那幾種。其餘的歸成 `.other`。
public enum TranscriptionEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    /// 增量文字：只往後加，不改寫。
    case delta(itemID: String, text: String)
    /// commit 之後，這一段的完整文字與計費秒數。
    case completed(itemID: String, transcript: String, billedSeconds: Double)
    case committed(itemID: String)
    case error(code: String, message: String)
    case other(type: String)

    /// 解析一則訊息。不是合法的 JSON 物件、或沒有 `type` 欄位時回傳 nil。
    public init?(message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        let itemID = object["item_id"] as? String ?? ""
        switch type {
        case "session.created", "transcription_session.created":
            self = .sessionCreated
        case "session.updated", "transcription_session.updated":
            self = .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            self = .delta(itemID: itemID, text: object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            let usage = object["usage"] as? [String: Any]
            let seconds = (usage?["seconds"] as? NSNumber)?.doubleValue ?? 0
            self = .completed(itemID: itemID, transcript: object["transcript"] as? String ?? "", billedSeconds: seconds)
        case "input_audio_buffer.committed":
            self = .committed(itemID: itemID)
        case "error":
            let error = object["error"] as? [String: Any]
            self = .error(code: error?["code"] as? String ?? "", message: error?["message"] as? String ?? "")
        default:
            self = .other(type: type)
        }
    }
}

/// 送給伺服器的訊息。
public enum TranscriptionCommand {
    /// `prompt` 的長度上限（實測：超過會被拒絕）。
    public static let promptLimit = 1_024

    /// 設定訊息。伺服器接受之後回 `session.updated`；有任何一項不合法就回 `error`，整份設定都不生效。
    ///
    /// 不設定伺服器端的斷句（`turn_detection: null`）：這個模型不支援，要由用戶端決定何時 commit。
    public static func sessionUpdate(_ settings: TranscriptionSettings) -> String {
        var transcription: [String: Any] = [
            "model": settings.model,
            "delay": settings.delay,
            "languages": settings.languages,
        ]
        let keywords = cleaned(settings.keywords)
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        let prompt = settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { transcription["prompt"] = String(prompt.prefix(promptLimit)) }
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ]
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 一包音訊：base64 編碼的 PCM16。
    public static func append(_ chunk: AudioChunk) -> String {
        // base64 不含需要跳脫的字元，直接組字串，不必經過 JSON 編碼器
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + chunk.pcm16.base64EncodedString() + "\"}"
    }

    /// 請伺服器把目前收到的音訊當成一段、送出完整文字。
    public static let commit = "{\"type\":\"input_audio_buffer.commit\"}"

    /// 去掉空白的與重複的關鍵詞，保留原本的順序。
    public static func cleaned(_ keywords: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
