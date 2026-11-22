import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 磁碟滿了的時候，建立新的分段寫檔頭會失敗，留下打不開的分段檔（空的，或檔頭只寫了一部分）。
/// 列分段時略過它們（裡面沒有聲音），但結束處理合併並確認錄音之後也要刪掉：
/// 否則 `audio/` 刪不掉，跟著這一場搬進 Library。
@Suite("結束處理：磁碟滿了留下的分段檔", .timeLimit(.minutes(2)))
struct SessionFinalizerStubSegmentTests {
    @Test(
        "合併並確認錄音之後，打不開的分段檔（空的，或檔頭沒寫完）也一起刪掉，audio 資料夾不會跟著搬進 Library",
        arguments: [0, 8])
    func removesUnreadableSegmentsAfterAVerifiedMerge(stubBytes: Int) async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let working = tmp.url.appendingPathComponent("Working", isDirectory: true)
        let library = tmp.url.appendingPathComponent("Library", isDirectory: true)
        let session = try Finished.makeSession(in: working)
        // 第三個分段只建立了檔案，檔頭沒寫完：0 個位元組，或只有開頭幾個位元組
        let header = try Data(contentsOf: session.audioDirectoryURL.appendingPathComponent("000.caf")).prefix(stubBytes)
        try header.write(to: session.audioDirectoryURL.appendingPathComponent("002.caf"))
        // 前提：列分段時略過它，合併只用前兩段（裡面沒有聲音）
        #expect(try RecordingFiles.segments(in: session.audioDirectoryURL).map(\.index) == [0, 1])

        let finalizer = SessionFinalizer(options: FinalizationOptions(libraryRoot: library))
        let published = try await withDeadline(.seconds(30)) { try await finalizer.finalize(session) }

        try Finished.expectPublished(published, in: library)
        #expect(!fileExists(published.audioDirectoryURL))
        #expect(filePaths(in: working).isEmpty)
    }
}
