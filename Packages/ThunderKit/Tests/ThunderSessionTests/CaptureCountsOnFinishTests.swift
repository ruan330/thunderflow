import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 收音端的完整性計數（RingBuffer 丟掉的樣本、裝置回報的不連續）要在場次交出鎖之前寫進 `session.json`：
/// 交出鎖之後，別的程式的結束處理就可能開始改寫它，這時再寫一次會蓋掉對方的紀錄（HANDOVER.md P8）。
@Suite("RecordingSession：收音端的完整性計數", .timeLimit(.minutes(2)))
struct CaptureCountsOnFinishTests {
    @Test("結束時帶入收音端的計數：finish 回傳時 session.json 已經有這些計數，場次的鎖也已經交出，之後不必再寫一次")
    func finishWritesCaptureCountsBeforeReleasingTheLock() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let engine = ScriptedEngine(.captions(every: 2))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine)
        session.start()
        try await feedInLockstep(session, engine: engine, seconds: 2)

        let meta = try await withDeadline(.seconds(30)) {
            try await session.finish(ringDroppedSamples: 480, captureDiscontinuities: 3)
        }

        #expect(meta.state == .finalizing)
        #expect(meta.integrity.ringDroppedSamples == 480)
        #expect(meta.integrity.captureDiscontinuities == 3)
        #expect(!meta.integrity.isRecordingComplete)
        // 鎖已經交出：別人（例如另一個 App 的結束處理）這時拿到鎖，讀到的就是完整的計數
        let lock = try #require(try SessionLock.acquire(directory))
        defer { lock.release() }
        #expect(try directory.loadMeta() == meta)
    }
}
