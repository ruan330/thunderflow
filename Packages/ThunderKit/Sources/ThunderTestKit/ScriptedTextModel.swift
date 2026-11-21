import Foundation
import ThunderCore

/// 照劇本回答的假文字模型：不連網路，回答只取決於請求的內容與這是第幾次請求。
///
/// 也可以演出故障：回錯誤、卡住不回答（被取消才結束）、過一段時間才回答。
public final class ScriptedTextModel: TextModel, @unchecked Sendable {
    public enum Reply: Sendable {
        /// 回答這段文字，切成 `pieces` 片依序送出。
        case text(String, pieces: Int = 1)
        /// 以這個錯誤結束。
        case failure(TextModelError)
        /// 卡住：不送任何東西，被取消才結束。
        case stall
        /// 先等這麼久（真實時間），再回答這段文字。
        case delayed(Duration, String)
    }

    private let reply: @Sendable (TextRequest, Int) -> Reply
    private let state = LockedValue<[TextRequest]>([])
    private let cancelled = LockedValue(0)

    /// - Parameter reply: 決定怎麼回答。第二個參數是這是第幾次請求（從 0 開始）。
    public init(reply: @escaping @Sendable (TextRequest, Int) -> Reply) {
        self.reply = reply
    }

    /// 每次都回答同一段文字。
    public convenience init(answer: String) {
        self.init { _, _ in .text(answer) }
    }

    /// 到目前為止收到的請求，依到達順序。
    public var requests: [TextRequest] { state.value }

    /// 被取消（還沒回答完，讀的人就不讀了）的請求數。
    public var cancelledCount: Int { cancelled.value }

    public func stream(_ request: TextRequest) -> AsyncThrowingStream<String, any Error> {
        let index = state.withValue { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        let reply = reply(request, index)
        let cancelled = cancelled
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch reply {
                    case .text(let text, let pieces):
                        for piece in Self.split(text, into: pieces) { continuation.yield(piece) }
                        continuation.finish()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .stall:
                        try await Task.sleep(for: .seconds(3_600))
                        continuation.finish()
                    case .delayed(let delay, let text):
                        try await Task.sleep(for: delay)
                        continuation.yield(text)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    cancelled.withValue { $0 += 1 }
                    task.cancel()
                }
            }
        }
    }

    /// 把文字切成差不多一樣長的 `count` 片（依字元，不會切壞中文字）。
    private static func split(_ text: String, into count: Int) -> [String] {
        let characters = Array(text)
        guard count > 1, characters.count > 1 else { return [text] }
        let size = max(1, Int((Double(characters.count) / Double(count)).rounded(.up)))
        return stride(from: 0, to: characters.count, by: size).map {
            String(characters[$0..<min($0 + size, characters.count)])
        }
    }
}
