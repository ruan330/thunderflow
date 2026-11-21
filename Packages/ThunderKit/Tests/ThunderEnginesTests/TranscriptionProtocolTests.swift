import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

@Suite("轉錄連線：訊息的格式")
struct TranscriptionProtocolTests {
    private func session(_ settings: TranscriptionSettings) throws -> [String: Any] {
        let object = try jsonObject(TranscriptionCommand.sessionUpdate(settings))
        #expect(object["type"] as? String == "session.update")
        return try #require(object["session"] as? [String: Any])
    }

    private func input(_ settings: TranscriptionSettings) throws -> [String: Any] {
        let session = try session(settings)
        let audio = try #require(session["audio"] as? [String: Any])
        return try #require(audio["input"] as? [String: Any])
    }

    @Test("設定訊息：純轉錄、24 kHz PCM、模型、delay、語言、關鍵詞，而且明確關閉伺服器端的斷句")
    func sessionUpdate() throws {
        var settings = TranscriptionSettings()
        settings.keywords = ["AgentCore", "Karpenter"]
        settings.prompt = "A keynote about agents."

        let session = try session(settings)
        #expect(session["type"] as? String == "transcription")
        let input = try input(settings)
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        // 這個模型不支援伺服器端的斷句；不寫明 null 的話，連線會停在預設的 server_vad
        #expect(input.keys.contains("turn_detection"))
        #expect(input["turn_detection"] is NSNull)

        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["delay"] as? String == "low")
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["keywords"] as? [String] == ["AgentCore", "Karpenter"])
        #expect(transcription["prompt"] as? String == "A keynote about agents.")
    }

    @Test("prompt 超過 1,024 個字元的部分會被截掉；空的 prompt 與關鍵詞不出現在設定裡")
    func promptLimit() throws {
        var settings = TranscriptionSettings()
        settings.prompt = String(repeating: "字", count: 2_000)
        let longInput = try input(settings)
        let long = try #require(longInput["transcription"] as? [String: Any])
        #expect((long["prompt"] as? String)?.count == 1_024)

        settings.prompt = "  \n"
        settings.keywords = ["", "  "]
        let emptyInput = try input(settings)
        let empty = try #require(emptyInput["transcription"] as? [String: Any])
        #expect(empty["prompt"] == nil)
        #expect(empty["keywords"] == nil)
    }

    @Test("關鍵詞去掉頭尾的空白、空白的與重複的（不分大小寫），順序不變")
    func keywords() {
        #expect(TranscriptionCommand.cleaned([" AgentCore ", "", "Karpenter", "agentcore", "S3 Vectors", "Karpenter"]) == ["AgentCore", "Karpenter", "S3 Vectors"])
    }

    @Test("音訊包是 base64 的 PCM16，解回來一模一樣")
    func append() throws {
        let samples = Signal.sine(frequency: 440, sampleRate: 24_000, duration: 0.2)
        let chunk = try #require(Signal.audioChunks(samples).first)
        let message = TranscriptionCommand.append(chunk)

        let object = try jsonObject(message)
        #expect(object["type"] as? String == "input_audio_buffer.append")
        let encoded = try #require(object["audio"] as? String)
        let decoded = try #require(Data(base64Encoded: encoded))
        #expect(decoded == chunk.pcm16)
        #expect(decoded.count == 9_600)
    }

    @Test("讀得懂錄下來的每一種事件")
    func parsesRecordedEvents() throws {
        var counts: [String: Int] = [:]
        var text = ""
        var billed = 0.0
        for line in try RealtimeFixture.load("keynote-commit-on-pause").serverLines {
            switch try recordedEvent(line) {
            case .sessionCreated: counts["created", default: 0] += 1
            case .sessionUpdated: counts["updated", default: 0] += 1
            case .delta(let itemID, let delta):
                #expect(!itemID.isEmpty)
                text += delta
                counts["delta", default: 0] += 1
            case .completed(let itemID, _, let seconds):
                #expect(!itemID.isEmpty)
                billed += seconds
                counts["completed", default: 0] += 1
            case .committed: counts["committed", default: 0] += 1
            case .error: counts["error", default: 0] += 1
            case .other: counts["other", default: 0] += 1
            }
        }
        #expect(counts["created"] == 1)
        #expect(counts["updated"] == 1)
        #expect(counts["completed"] == 20)
        #expect(counts["committed"] == 20)
        #expect(counts["error"] == nil)
        #expect((counts["delta"] ?? 0) > 200)
        #expect(text.contains("AgentCore"))
        #expect(billed > 90 && billed < 130, "計費秒數是每一段無條件進位後的總和：\(billed)")
    }

    @Test("讀得懂設定被拒絕的錯誤事件")
    func parsesError() throws {
        let line = try #require(try RealtimeFixture.load("rejected-turn-detection").serverLines.last)
        guard case .error(let code, let message) = try recordedEvent(line) else {
            Issue.record("應該是 error 事件")
            return
        }
        #expect(!code.isEmpty)
        #expect(!message.isEmpty)
    }

    @Test("不是 JSON、或沒有 type 的訊息：回傳 nil，不會當掉")
    func garbage() {
        #expect(TranscriptionEvent(message: "") == nil)
        #expect(TranscriptionEvent(message: "not json") == nil)
        #expect(TranscriptionEvent(message: "[1,2,3]") == nil)
        #expect(TranscriptionEvent(message: #"{"no_type":true}"#) == nil)
        #expect(TranscriptionEvent(message: #"{"type":"something.new"}"#) == .other(type: "something.new"))
    }
}
