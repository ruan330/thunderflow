import Foundation

/// 一條即時連線（WebSocket）。引擎對外可以替換的接口：正式環境用 `URLSession`，測試時換成重播事件的假連線。
public protocol RealtimeSocket: Sendable {
    /// 送出一則文字訊息。連線已經關閉時丟出錯誤。
    func send(_ message: String) async throws
    /// 等下一則訊息。連線關閉時丟出 `RealtimeSocketClosed`。
    func receive() async throws -> String
    /// 關閉連線。可以重複呼叫；進行中的 `receive` 會以錯誤結束。
    func close()
}

/// 連線關閉了。`reason` 決定引擎接下來怎麼做（重試或回報失敗）。
public struct RealtimeSocketClosed: Error, Equatable, Sendable {
    public var reason: TranscriptionLink.CloseReason

    public init(reason: TranscriptionLink.CloseReason) {
        self.reason = reason
    }
}

/// 建立即時連線。
public protocol RealtimeConnector: Sendable {
    /// 開始建立連線並立即返回；連不上時，錯誤會從第一次 `receive` 丟出來。
    func connect(to url: URL, headers: [String: String]) -> any RealtimeSocket
}

/// 用 `URLSessionWebSocketTask` 實作的連線。
public struct URLSessionRealtimeConnector: RealtimeConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL, headers: [String: String]) -> any RealtimeSocket {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        // 完成事件會帶整段的文字，預設的 1 MB 上限不夠保險
        task.maximumMessageSize = 16 << 20
        task.resume()
        return Socket(task: task)
    }

    private final class Socket: RealtimeSocket, @unchecked Sendable {
        // @unchecked Sendable：`URLSessionWebSocketTask` 本身可以從任何執行緒使用。
        private let task: URLSessionWebSocketTask

        init(task: URLSessionWebSocketTask) {
            self.task = task
        }

        func send(_ message: String) async throws {
            try await task.send(.string(message))
        }

        func receive() async throws -> String {
            do {
                switch try await task.receive() {
                case .string(let text): return text
                case .data(let data): return String(decoding: data, as: UTF8.self)
                @unknown default: return ""
                }
            } catch {
                throw RealtimeSocketClosed(reason: reason())
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }

        /// 從 HTTP 狀態碼與關閉代碼判斷為什麼斷線。
        private func reason() -> TranscriptionLink.CloseReason {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .unauthorized }
            if status == 429 { return .rateLimited }
            // 實測：API Key 無效時，伺服器先送 error 事件，再以代碼 3000 關閉
            if task.closeCode.rawValue == 3000 { return .unauthorized }
            return .lost
        }
    }
}
