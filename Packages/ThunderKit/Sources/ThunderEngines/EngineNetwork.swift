import Foundation

/// 引擎連到服務用的網路設定：錄音中不做不必要的工作（DESIGN.md 9.8 節，HANDOVER.md P9）。
public enum EngineNetwork {
    /// 引擎預設用的連線：不寫磁碟快取、不存 cookie。翻譯的回應不會再用到，
    /// 寫進磁碟的快取只花 CPU 與磁碟（`URLSession.shared` 錄音中約 0.3 點 CPU，實測）。
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// 即時連線握手時送的 `Sec-WebSocket-Extensions`：一個伺服器不認得的擴充，取代系統自動要求的
    /// permessage-deflate（壓縮）。送出的音訊是 base64，幾乎壓不小，壓縮只花 CPU（錄音中約 0.8 點，實測）。
    /// 伺服器照 RFC 6455 忽略不認得的擴充：OpenAI 的即時端點照常連線，回覆裡沒有任何擴充（2026-11-21 實測）。
    /// 不可以送空字串：會被拒絕（HTTP 400）。
    static let uncompressed = "x-thunderflow-uncompressed"

    /// 即時連線（WebSocket）的握手請求。
    public static func webSocketRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(uncompressed, forHTTPHeaderField: "Sec-WebSocket-Extensions")
        request.timeoutInterval = 30
        return request
    }
}
