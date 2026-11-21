import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 正在錄音或正在做結束處理的場次，不會被別人當成「上次中斷的場次」拿去復原、收尾。
///
/// 背景：App 啟動後（或多開一個視窗、多開一個 App）會把工作目錄裡狀態還是 recording 的場次當成中斷的場次復原。
/// 狀態本身分不出「正在錄」和「上次中斷」，所以由場次的鎖來分：鎖由錄音中的場次（或結束處理）持有，
/// 程式結束（包括當機、被強制結束）時由系統釋放。程式被強制結束之後找得到中斷的場次，由當機安全的測試驗證。
@Suite("場次的鎖：正在處理的場次不會被別人拿走")
struct SessionLockingTests {
    @Test("錄音中的場次持有鎖，不會被當成中斷的場次，也不能做結束處理；正常結束之後交出鎖")
    func liveSessionIsNotInterrupted() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let library = tmp.url.appendingPathComponent("Library", isDirectory: true)
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 1)))
        session.start()
        try feed(session, seconds: 1)

        #expect(SessionLock.isHeld(directory))
        #expect(try SessionRecovery.findInterrupted(in: tmp.url).isEmpty)
        await #expect(throws: SessionFinalizerError.stillRecording) {
            try await SessionFinalizer(options: FinalizationOptions(libraryRoot: library)).finalize(directory)
        }
        #expect(try directory.loadMeta().state == .recording)

        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }
        #expect(meta.state == .finalizing)
        #expect(!SessionLock.isHeld(directory))
        #expect(try SessionRecovery.findInterrupted(in: tmp.url).isEmpty)
    }

    @Test("錄音中的物件沒有正常結束就不見了（程式裡的錄音被放掉），場次會被當成中斷的場次")
    func abandonedSessionIsInterrupted() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        var recorded: SessionDirectory?
        do {
            let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: ScriptedEngine(.captions(every: 1)))
            try feed(session, seconds: 1)
            withExtendedLifetime(session) { #expect(SessionLock.isHeld(directory)) }
            recorded = directory
        }

        let found = try SessionRecovery.findInterrupted(in: tmp.url)
        #expect(found.count == 1)
        #expect(found.first?.directory == recorded)
    }

    @Test("同一場的結束處理同時只能有一個：進行中時再做一次、或重新產生摘要，都丟出 inProgress 而且不送請求；做完之後交出鎖")
    func oneFinalizationAtATime() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let working = tmp.url.appendingPathComponent("Working", isDirectory: true)
        let library = tmp.url.appendingPathComponent("Library", isDirectory: true)
        let session = try Finished.makeSession(in: working)
        // 第一個請求卡住（到摘要的時限為止），之後的請求立刻失敗
        let model = ScriptedTextModel { _, index in
            index == 0 ? .stall : .failure(.http(status: 500, message: "不應該送出"))
        }
        var options = FinalizationOptions(libraryRoot: library)
        options.textModel = model
        options.summaryTimeout = .seconds(3)
        let finalizer = SessionFinalizer(options: options)

        let first = Task { try await finalizer.finalize(session) }
        // 等第一個結束處理走到摘要：這時資料夾已經搬進 Library
        #expect(await waitUntil(timeout: .seconds(10)) { !model.requests.isEmpty })
        let published = try #require(SessionLibrary.list(root: library).first?.directory)
        #expect(SessionLock.isHeld(published))

        await #expect(throws: SessionFinalizerError.inProgress) { try await finalizer.finalize(published) }
        await #expect(throws: SessionFinalizerError.inProgress) { try await finalizer.regenerateSummary(published) }
        #expect(model.requests.count == 1)

        let done = try await withDeadline(.seconds(15)) { try await first.value }
        #expect(done == published)
        #expect(!SessionLock.isHeld(done))
        let meta = try done.loadMeta()
        #expect(meta.state == .complete)
        #expect(meta.failedSteps == ["summary"])
    }
}
