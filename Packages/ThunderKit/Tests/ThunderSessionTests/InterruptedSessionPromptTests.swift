import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 上次沒有正常結束的場次（當機、被強制結束）：開啟 App 時先問，不自動收尾、也不自動接著錄（D26、DESIGN.md 5.5 節）。
@Suite("當機之後重新開啟：先問使用者")
struct InterruptedSessionPromptTests {
    private let now = Date(timeIntervalSince1970: 1_796_200_000)

    private func session(title: String = "", minutesAgo: Double, recorded: Double) -> InterruptedSession {
        InterruptedSession(
            directory: SessionDirectory(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)", isDirectory: true)),
            meta: SessionMeta(title: title, startedAt: now.addingTimeInterval(-minutesAgo * 60 - recorded), state: .recording),
            recordedDuration: recorded, segmentCount: 1, lastWrittenAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test("沒有上次中斷的場次：不問")
    func nothingToAsk() {
        #expect(InterruptedSessionPrompt(sessions: [], now: now) == nil)
    }

    @Test("一場：說是哪一場、多久以前中斷、已經錄下多長，問要現在結束並產生逐字稿，還是稍後再決定")
    func oneSession() throws {
        let prompt = try #require(
            InterruptedSessionPrompt(sessions: [session(title: "Building Agents", minutesAgo: 14.3, recorded: 1_930)], now: now))

        #expect(prompt.message.hasPrefix("上次的錄音「Building Agents」在 14 分鐘前中斷了，已經錄下 32:10。"))
        #expect(prompt.message.contains("結束並產生逐字稿"))
        #expect(prompt.message.contains("稍後再決定"))
        #expect(InterruptedSessionPrompt.finishLabel == "結束並產生逐字稿")
        #expect(InterruptedSessionPrompt.laterLabel == "稍後再決定")
    }

    @Test("沒有標題的場次：不顯示標題")
    func untitledSession() throws {
        let prompt = try #require(InterruptedSessionPrompt(sessions: [session(minutesAgo: 3, recorded: 95)], now: now))

        #expect(prompt.message.hasPrefix("上次的錄音在 3 分鐘前中斷了，已經錄下 1:35。"))
    }

    @Test("好幾場：一次問，說有幾場，以及最近的一場多久以前中斷")
    func severalSessions() throws {
        let sessions = [
            session(title: "A", minutesAgo: 600, recorded: 60), session(title: "B", minutesAgo: 2, recorded: 60),
            session(title: "C", minutesAgo: 90, recorded: 60),
        ]

        let prompt = try #require(InterruptedSessionPrompt(sessions: sessions, now: now))

        #expect(prompt.message.hasPrefix("有 3 場錄音上次沒有正常結束，最近的一場在 2 分鐘前中斷。"))
    }

    @Test(
        "多久以前：不到 1 分鐘、幾分鐘、幾小時、幾天",
        arguments: [(0.5, "不到 1 分鐘前"), (14.9, "14 分鐘前"), (185, "3 小時前"), (2_940, "2 天前")] as [(Double, String)])
    func howLongAgo(minutesAgo: Double, expected: String) throws {
        let prompt = try #require(InterruptedSessionPrompt(sessions: [session(minutesAgo: minutesAgo, recorded: 60)], now: now))

        #expect(prompt.message.hasPrefix("上次的錄音在 \(expected)中斷了"), "\(prompt.message)")
    }

    @Test("找出中斷的場次時記下最後寫入的時間，用來說多久以前中斷")
    func findInterruptedNotesTheLastWrite() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        _ = try Finished.makeSession(in: tmp.url) { $0.state = .recording }

        let found = try #require(try SessionRecovery.findInterrupted(in: tmp.url).first)

        #expect(abs(found.lastWrittenAt.timeIntervalSinceNow) < 60)
    }
}
