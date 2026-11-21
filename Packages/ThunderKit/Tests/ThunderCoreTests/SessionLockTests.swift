import Foundation
import Testing
import ThunderCore
import ThunderTestKit

@Suite("SessionLock：同一個場次同時只能有一方處理")
struct SessionLockTests {
    private func makeDirectory(in tmp: TemporaryDirectory, _ name: String = "session") throws -> SessionDirectory {
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent(name, isDirectory: true))
        try directory.create()
        return directory
    }

    /// 資料夾裡所有東西的相對路徑。
    private func listing(_ folder: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }

    @Test("拿到鎖之後，別人（包括同一個程式裡的其他地方）拿不到；釋放之後就拿得到，重複釋放不算錯")
    func exclusive() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        #expect(!SessionLock.isHeld(directory))

        let lock = try #require(try SessionLock.acquire(directory))
        #expect(SessionLock.isHeld(directory))
        #expect(try SessionLock.acquire(directory) == nil)

        lock.release()
        lock.release()
        #expect(!SessionLock.isHeld(directory))
        let again = try SessionLock.acquire(directory)
        #expect(again != nil)
        again?.release()
    }

    @Test("資料夾改名、搬到同一個磁碟的其他位置之後，鎖還在")
    func followsMoves() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let lock = try #require(try SessionLock.acquire(directory))

        let moved = SessionDirectory(url: tmp.url.appendingPathComponent("Library/2026-11-21 新的名字", isDirectory: true))
        try FileManager.default.createDirectory(at: moved.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory.url, to: moved.url)

        #expect(SessionLock.isHeld(moved))
        #expect(try SessionLock.acquire(moved) == nil)
        lock.release()
        #expect(!SessionLock.isHeld(moved))
    }

    @Test("持有鎖的物件不見了（例如程式裡的錄音物件被放掉），鎖跟著釋放")
    func releasedWithTheObject() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)

        do {
            let lock = try SessionLock.acquire(directory)
            withExtendedLifetime(lock) {
                #expect(lock != nil)
                #expect(SessionLock.isHeld(directory))
            }
        }

        #expect(!SessionLock.isHeld(directory))
    }

    @Test("資料夾不存在：拿鎖丟出錯誤，查詢回答沒有人持有")
    func missingDirectory() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let missing = SessionDirectory(url: tmp.url.appendingPathComponent("missing", isDirectory: true))

        #expect(throws: (any Error).self) { try SessionLock.acquire(missing) }
        #expect(!SessionLock.isHeld(missing))
    }

    @Test("鎖不會在場次資料夾裡留下任何檔案")
    func leavesNoFiles() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let before = listing(directory.url)

        let lock = try #require(try SessionLock.acquire(directory))
        #expect(SessionLock.isHeld(directory))
        #expect(listing(directory.url) == before)
        lock.release()
        #expect(listing(directory.url) == before)
    }
}
