import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 錄音檔寫不進去（例如磁碟滿了）時，錄音路徑不能卡住，也不能靜靜地少掉聲音：
/// 沒錄到的長度要記進完整性，而且送去轉錄的音訊和錄下來的一致，字幕的時間才對得上錄音。
@Suite("錄音檔寫不進去")
struct RecordingWriteFailureTests {
    @Test("寫不進去的聲音記成「沒錄到」：process 丟出錯誤、長度記進 session.json；能寫之後接著錄；送給引擎的音訊和錄下來的一樣長")
    func unrecordedAudioIsAccounted() async throws {
        let tmp = try TemporaryDirectory()
        let engine = ScriptedEngine(.captions(every: 1))
        let (session, directory) = try Fixture.makeSession(in: tmp.url, engine: engine) { $0.segmentDuration = 1 }
        let audio = directory.audioDirectoryURL
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audio.path)
            tmp.remove()
        }
        session.start()

        // 30 ms 一包：每 1 秒一個分段，所以分段的邊界會落在一包的中間
        let chunk = Signal.constant(0.25, count: Int(Fixture.sampleRate * 0.03))
        func send(seconds: Double) -> Int {
            var failures = 0
            for _ in 0..<Int((seconds / 0.03).rounded()) {
                do {
                    try chunk.withUnsafeBufferPointer { try session.process($0) }
                } catch {
                    failures += 1
                }
            }
            return failures
        }

        #expect(send(seconds: 1.5) == 0)
        // 錄音的資料夾變成不能寫：開著的分段還能寫到滿（2.0 秒），下一個分段建立不了
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: audio.path)
        #expect(send(seconds: 0.9) == 14)
        #expect(abs(session.audioTime.seconds - 2.0) < 1e-6)
        #expect(abs(session.unrecordedSeconds - 0.4) < 1e-6)

        // 又可以寫了：接著錄進新的分段
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audio.path)
        #expect(send(seconds: 0.6) == 0)

        let meta = try await withDeadline(.seconds(10)) { try await session.finish() }
        #expect(abs(meta.durationSeconds - 2.6) < 1e-6)
        #expect(abs(meta.integrity.unrecordedSeconds - 0.4) < 1e-6)
        #expect(!meta.integrity.isRecordingComplete)
        #expect(try directory.loadMeta() == meta)
        #expect(abs(RecordingFiles.totalDuration(of: try RecordingFiles.segments(in: audio)) - 2.6) < 1e-6)
        // 沒錄到的聲音也沒有送去轉錄：送給引擎的長度等於錄下來的長度
        #expect(abs(engine.receivedDuration - meta.durationSeconds) < 0.005)
    }
}
