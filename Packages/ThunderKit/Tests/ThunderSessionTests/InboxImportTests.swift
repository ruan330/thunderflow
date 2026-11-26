import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// Mac 收進手機交來的場次（DESIGN.md 5.10 節，D36）：先複製到工作目錄裡的暫存位置、再核對一次大小，
/// 然後改名成 `<工作目錄>/<場次 id>/`，最後把收件匣裡的那一份移走；之後走一般的結束處理。
@Suite("Mac 收進手機交來的場次：複製到暫存、核對大小、改名成場次 id，再照常做結束處理（D36）", .timeLimit(.minutes(1)))
struct InboxImportTests {
    @Test("收進工作目錄的「場次 id/」：每個檔案一模一樣，handoff.json 留在 .thunderflow/；收件匣裡的那一份移走")
    func receivesIntoTheWorkingRoot() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, id) = try roots.handOff()
        let expected = try folderSnapshot(folder)
        let removed = LockedValue<[URL]>([])

        let report = roots.reader(removed: removed).collect()

        let directory = SessionDirectory(url: roots.working.appendingPathComponent(id.uuidString, isDirectory: true))
        #expect(report.received.map(\.id) == [id])
        #expect(report.received.map(\.directory.url.path) == [directory.url.path])
        #expect(report.received.map(\.from) == ["iPhone"])
        #expect(report.alreadyReceived.isEmpty)
        #expect(report.waiting.isEmpty)
        #expect(report.problems.isEmpty)
        #expect(try folderSnapshot(directory.url) == expected)
        #expect(removed.value.map(\.path) == [folder.path])
        #expect(!fileExists(folder))
        // 工作目錄裡只有這一場：暫存的複製不留下
        #expect(roots.workingItems == [id.uuidString])
        // 收進來的就是一般的場次：前三步做完、狀態 finalizing，列在過去錄音的清單上（處理中）
        let meta = try directory.loadMeta()
        #expect(meta.state == .finalizing)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio"])
        #expect(SessionLibrary.list(library: roots.library, working: roots.working).map(\.id) == [id])
    }

    @Test("收件匣裡多出來、沒有列在 handoff.json 的檔案（.DS_Store、iCloud 的暫存檔、其他檔案）不複製")
    func copiesOnlyListedFiles() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        let expected = try folderSnapshot(folder)
        for path in [".DS_Store", ".thunderflow/.DS_Store", ".transcript.md.icloud", "extra.txt"] {
            try writeFile("雜檔", at: folder.appendingPathComponent(path))
        }

        let report = roots.reader().collect()

        let directory = try #require(report.received.first?.directory)
        #expect(try folderSnapshot(directory.url) == expected)
    }

    @Test(
        "同一個 id 已經在 Library 或工作目錄裡（資料夾名稱不同也算）：不再複製，只把收件匣裡的那一份移走",
        arguments: ["Library", "工作目錄"])
    func skipsSessionsAlreadyPresent(_ place: String) throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, id) = try roots.handOff()
        // 已經收過的同一場（可能已經自動命名、搬進 Library）
        let root = place == "Library" ? roots.library : roots.working
        let existing = SessionDirectory(
            url: root.appendingPathComponent("2026-12-02 1030 Building Agents with Bedrock", isDirectory: true))
        try FileManager.default.createDirectory(at: existing.hiddenDirectoryURL, withIntermediateDirectories: true)
        try existing.saveMeta(SessionMeta(id: id, title: Finished.title, startedAt: Finished.startedAt, state: .complete))
        let library = try folderSnapshot(roots.library)
        let working = try folderSnapshot(roots.working)
        let workingItems = roots.workingItems
        let removed = LockedValue<[URL]>([])

        let report = roots.reader(removed: removed).collect()

        #expect(report.received.isEmpty)
        #expect(report.alreadyReceived == [id])
        #expect(report.problems.isEmpty)
        #expect(removed.value.map(\.path) == [folder.path])
        #expect(!fileExists(folder))
        #expect(try folderSnapshot(roots.library) == library)
        #expect(try folderSnapshot(roots.working) == working)
        #expect(roots.workingItems == workingItems)
    }

    @Test("收好了，但收件匣裡的那一份移不走：收進來的不受影響；下次看到時當成已經收過，再移一次，還是移不走就說明原因")
    func removalFailureIsRetried() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, id) = try roots.handOff()
        let failing = SessionInbox(inbox: roots.inbox, workingRoot: roots.working, libraryRoot: roots.library) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        let first = failing.collect()
        #expect(first.received.map(\.id) == [id])
        #expect(fileExists(folder))
        #expect(roots.workingItems == [id.uuidString])

        let second = failing.collect()
        #expect(second.received.isEmpty)
        #expect(second.problems.map(\.folder.path) == [folder.path])
        #expect(second.problems.first?.reason.contains("移不走") == true)
        #expect(roots.workingItems == [id.uuidString])

        let third = roots.reader().collect()
        #expect(third.received.isEmpty)
        #expect(third.alreadyReceived == [id])
        #expect(third.problems.isEmpty)
        #expect(!fileExists(folder))
        #expect(roots.workingItems == [id.uuidString])
    }

    @Test("複製之後大小和 handoff.json 對不上（看過之後檔案又變了）：不收，暫存的複製刪掉，收件匣裡的那一份留著")
    func sizeChangedAfterScan() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        let reader = roots.reader()
        guard case .ready(let manifest) = try reader.scan().first?.status else {
            Issue.record("應該可以收")
            return
        }
        // 看過之後、收之前，逐字稿又變長了
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("transcript.md"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("多一行\n".utf8))
        try handle.close()

        #expect(throws: SessionHandoffError.self) { try reader.receive(folder, manifest: manifest) }

        #expect(roots.workingItems.isEmpty)
        #expect(fileExists(ManifestFile.url(in: folder)))
        // 下次看的時候大小和清單對不上：當成還沒到齊
        #expect(try reader.scan() == [InboxEntry(folder: folder, status: .waiting)])
    }

    @Test("磁碟空間不夠（收完之後留不下給錄音用的空間）：不收，說明原因，收件匣裡的那一份留著")
    func refusesWithoutEnoughSpace() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        var reader = roots.reader()
        reader.reservedSpace = .max / 4

        let report = reader.collect()

        #expect(report.received.isEmpty)
        #expect(report.problems.map(\.folder.path) == [folder.path])
        #expect(report.problems.first?.reason.contains("空間") == true)
        #expect(fileExists(ManifestFile.url(in: folder)))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("另一個 ThunderFlow 正在收這一份（收件匣裡的那一份被鎖住）：這一次什麼都不做")
    func skipsWhileAnotherIsReceiving() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (folder, _) = try roots.handOff()
        let reader = roots.reader()
        guard case .ready(let manifest) = try reader.scan().first?.status else {
            Issue.record("應該可以收")
            return
        }
        let lock = try #require(try SessionLock.acquire(SessionDirectory(url: folder)))
        defer { lock.release() }

        #expect(try reader.receive(folder, manifest: manifest) == .busy)
        #expect(reader.collect() == InboxReport())
        #expect(fileExists(ManifestFile.url(in: folder)))
        #expect(roots.workingItems.isEmpty)
    }

    @Test("一次收進好幾場；還在等的、有問題的照樣留在收件匣裡；說明收到幾場")
    func receivesSeveralAtOnce() throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        let (first, firstID) = try roots.handOff()
        let (second, secondID) = try roots.handOff()
        let (waiting, _) = try roots.handOff()
        try FileManager.default.removeItem(at: ManifestFile.url(in: waiting))
        let (rejected, _) = try roots.handOff()
        try ManifestFile.edit(in: rejected) { $0["version"] = 2 }

        let report = roots.reader().collect()

        #expect(Set(report.received.map(\.id)) == [firstID, secondID])
        #expect(report.waiting.map(\.path) == [waiting.path])
        #expect(report.problems.map(\.folder.path) == [rejected.path])
        #expect(!fileExists(first))
        #expect(!fileExists(second))
        #expect(fileExists(waiting))
        #expect(fileExists(rejected))
        #expect(roots.workingItems == [firstID.uuidString, secondID.uuidString].sorted())
        #expect(report.announcement == "收到 iPhone 錄的 2 場，正在處理。")
    }

    @Test("沒有收進新的場次時沒有要說的話")
    func nothingToAnnounce() {
        #expect(InboxReport().announcement == nil)
        #expect(
            InboxReport(alreadyReceived: [UUID()], waiting: [URL(fileURLWithPath: "/tmp/inbox/x")]).announcement == nil)
    }

    @Test("收進來的場次在 Mac 上照常做完結束處理：搬進 Library、狀態 complete，handoff.json 跟著；沒有文字模型時略過摘要")
    func receivedSessionFinalizesOnTheMac() async throws {
        let roots = try HandoffRoots()
        defer { roots.tmp.remove() }
        // 手機：錄好的場次做到合併錄音，交到收件匣，再刪掉手機上的那一份
        let phone = try Finished.makeSession(in: roots.phone)
        var phoneOptions = FinalizationOptions(libraryRoot: roots.phone)
        phoneOptions.lastStep = .audio
        let phoneFinalizer = SessionFinalizer(options: phoneOptions)
        try await withDeadline(.seconds(30)) { try await phoneFinalizer.finalize(phone) }
        try SessionHandoff.export(phone, to: roots.inbox)
        try FileManager.default.removeItem(at: phone.url)

        // Mac：收進工作目錄，接著做一般的結束處理
        let report = roots.reader().collect()
        let received = try #require(report.received.first)
        let log = ProgressLog()
        let macFinalizer = SessionFinalizer(options: FinalizationOptions(libraryRoot: roots.library))
        let published = try await withDeadline(.seconds(30)) {
            try await macFinalizer.finalize(received.directory) { step, directory in log.record(step, directory) }
        }

        #expect(log.steps == [.publish, .summary])
        let meta = try published.loadMeta()
        #expect(meta.id == received.id)
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio", "publish"])
        #expect(meta.failedSteps.isEmpty)
        #expect(published.url.deletingLastPathComponent().path == roots.library.path)
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(try TranscriptBlocks.read(published.blocksURL) == Finished.blocks)
        #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 45) < 0.2)
        #expect(
            filePaths(in: published.url) == [
                ".thunderflow/blocks.jsonl", ".thunderflow/handoff.json", ".thunderflow/journal.jsonl",
                ".thunderflow/session.json", "recording.m4a", "transcript.md",
            ])
        #expect(SessionLibrary.list(library: roots.library, working: roots.working).map(\.directory) == [published])
        #expect(filePaths(in: roots.working).isEmpty)
        #expect(filePaths(in: roots.inbox).isEmpty)
    }
}
