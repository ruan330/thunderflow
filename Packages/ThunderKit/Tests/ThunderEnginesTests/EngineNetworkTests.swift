import Foundation
import Testing
import ThunderEngines

/// 引擎的網路設定：錄音中的 CPU（DESIGN.md 9.8 節，HANDOVER.md P9）。
@Suite("引擎的網路設定：錄音中不做不必要的工作")
struct EngineNetworkTests {
    @Test("引擎預設的連線不寫磁碟快取、不存 cookie：翻譯的回應不會再用到，寫進磁碟只花 CPU")
    func noDiskCache() {
        let configuration = EngineNetwork.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("即時連線的握手不要求壓縮（permessage-deflate）：音訊是 base64，幾乎壓不小，壓縮只花 CPU")
    func noCompression() throws {
        let url = try #require(URL(string: "wss://example.invalid/v1/realtime?intent=transcription"))
        let request = EngineNetwork.webSocketRequest(url: url, headers: ["Authorization": "Bearer test"])
        let extensions = try #require(request.value(forHTTPHeaderField: "Sec-WebSocket-Extensions"))
        #expect(!extensions.isEmpty, "空的值會被伺服器拒絕（實測 HTTP 400）")
        #expect(!extensions.contains("permessage-deflate"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        #expect(request.url == url)
        #expect(request.timeoutInterval == 30)
    }
}
