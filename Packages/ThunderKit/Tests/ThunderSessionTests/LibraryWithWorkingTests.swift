import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

@Suite("過去錄音的清單：也列出還沒搬進 Library 的場次（結束處理中或處理失敗），不列錄音中的")
struct LibraryWithWorkingTests {
    private struct Roots {
        let tmp: TemporaryDirectory
        var library: URL { tmp.url.appendingPathComponent("Library", isDirectory: true) }
        var working: URL { tmp.url.appendingPathComponent("Working", isDirectory: true) }

        init() throws {
            tmp = try TemporaryDirectory()
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    private func makeSession(
        in root: URL, named name: String? = nil, id: UUID = UUID(), minutesAfter minutes: Double, state: SessionState,
        completedSteps: [String] = []
    ) throws -> SessionDirectory {
        let directory = SessionDirectory(url: root.appendingPathComponent(name ?? id.uuidString, isDirectory: true))
        try directory.create()
        try directory.saveMeta(
            SessionMeta(
                id: id, title: name ?? "", startedAt: Date(timeIntervalSince1970: 1_796_000_000 + minutes * 60), state: state,
                completedSteps: completedSteps))
        return directory
    }

    @Test("工作目錄裡已經停止錄音、還沒搬進 Library 的場次（結束處理中，或處理失敗留下來的）：也列在清單裡")
    func includesUnpublished() throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let published = try makeSession(
            in: roots.library, named: "2026-12-01 1000 已發布", minutesAfter: 0, state: .complete,
            completedSteps: ["blocks", "transcript", "audio", "publish", "summary"])
        let justStopped = try makeSession(in: roots.working, minutesAfter: 10, state: .finalizing)
        let stuck = try makeSession(in: roots.working, minutesAfter: 5, state: .finalizing, completedSteps: ["blocks", "transcript"])

        let items = SessionLibrary.list(library: roots.library, working: roots.working)

        #expect(items.map(\.directory) == [justStopped, stuck, published])
    }

    @Test("工作目錄裡還在錄音（或中斷了還沒復原）的場次：不列出")
    func excludesRecording() throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        try makeSession(in: roots.working, minutesAfter: 0, state: .recording)
        let stopped = try makeSession(in: roots.working, minutesAfter: 1, state: .finalizing)

        let items = SessionLibrary.list(library: roots.library, working: roots.working)

        #expect(items.map(\.directory) == [stopped])
    }

    @Test("同一場同時在工作目錄與 Library 裡（搬進 Library 的途中）：只列一次，用 Library 裡的那一份")
    func listsEachSessionOnce() throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let id = UUID()
        try makeSession(in: roots.working, id: id, minutesAfter: 0, state: .finalizing, completedSteps: ["blocks", "transcript", "audio"])
        let moved = try makeSession(
            in: roots.library, named: "2026-12-01 1000 搬移中", id: id, minutesAfter: 0, state: .finalizing,
            completedSteps: ["blocks", "transcript", "audio", "publish"])

        let items = SessionLibrary.list(library: roots.library, working: roots.working)

        #expect(items.map(\.directory) == [moved])
        #expect(items.map(\.id) == [id])
    }

    @Test("工作目錄不存在：只列 Library 裡的場次")
    func missingWorkingFolder() throws {
        let roots = try Roots()
        defer { roots.tmp.remove() }
        let published = try makeSession(in: roots.library, named: "2026-12-01 1000 已發布", minutesAfter: 0, state: .complete)
        try FileManager.default.removeItem(at: roots.working)

        #expect(SessionLibrary.list(library: roots.library, working: roots.working).map(\.directory) == [published])
    }
}
