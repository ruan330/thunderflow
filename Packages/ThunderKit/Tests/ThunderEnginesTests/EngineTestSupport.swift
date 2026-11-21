import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 把錄下來的一行伺服器事件解析出來。
func recordedEvent(_ line: RealtimeFixture.Line) throws -> TranscriptionEvent {
    let message = try #require(line.message)
    return try #require(TranscriptionEvent(message: message))
}

/// 把一則 JSON 訊息解析成物件。
func jsonObject(_ text: String) throws -> [String: Any] {
    let raw = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(raw as? [String: Any])
}
