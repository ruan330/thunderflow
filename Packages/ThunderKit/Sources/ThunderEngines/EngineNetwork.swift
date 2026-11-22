import Foundation

/// 引擎連到服務用的網路設定。
public enum EngineNetwork {
    /// 引擎預設用的連線。
    public static let session = URLSession.shared

    /// 即時連線（WebSocket）的握手請求。
    public static func webSocketRequest(url: URL, headers: [String: String]) -> URLRequest {
        URLRequest(url: url)
    }
}
