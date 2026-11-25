import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit
import ThunderUI

@Suite("給 AI agent 的路徑：什麼時候可以複製（D34）")
struct AgentPathsTests {
    /// 一個場次資料夾：可以選擇有沒有即時逐字稿與 `transcript.md`、有沒有下載過教材。
    private func session(
        in tmp: TemporaryDirectory, liveTranscript: Bool = true, transcript: Bool = true, workshop: [String] = []
    ) throws -> SessionDirectory {
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("2026-12-01 1030 GameDay", isDirectory: true))
        try directory.create()
        if liveTranscript { try Data("x\n".utf8).write(to: directory.liveTranscriptURL) }
        if transcript { try Data("x\n".utf8).write(to: directory.transcriptURL) }
        if !workshop.isEmpty { try FileManager.default.createDirectory(at: directory.workshopURL, withIntermediateDirectories: true) }
        for name in workshop {
            try FileManager.default.createDirectory(
                at: directory.workshopURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        return directory
    }

    private func meta(title: String = "GameDay", steps: [String] = ["blocks", "transcript", "audio", "publish"]) -> SessionMeta {
        SessionMeta(
            title: title, startedAt: Date(timeIntervalSince1970: 1_796_178_600), state: .complete, completedSteps: steps)
    }

    @Test("錄音中：有即時逐字稿就可以複製它的路徑；寫不出來（檔案不存在）就不行")
    func recordingTranscript() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp)
        #expect(AgentPaths.recording(directory).transcript == directory.liveTranscriptURL)
        try FileManager.default.removeItem(at: directory.liveTranscriptURL)
        #expect(AgentPaths.recording(directory).transcript == nil)
    }

    @Test("錄音中：沒有下載過教材時不能複製教材路徑，下載過就可以")
    func recordingWorkshop() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp)
        #expect(AgentPaths.recording(directory).workshop == nil)
        try FileManager.default.createDirectory(
            at: directory.workshopURL.appendingPathComponent("Building with Generative AI", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(AgentPaths.recording(directory).workshop == directory.workshopURL)
    }

    @Test("教材資料夾是空的，或只有隱藏的東西（例如 .DS_Store）時，當成沒有下載過")
    func emptyWorkshop() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp)
        try FileManager.default.createDirectory(at: directory.workshopURL, withIntermediateDirectories: true)
        #expect(AgentPaths.recording(directory).workshop == nil)
        try Data().write(to: directory.workshopURL.appendingPathComponent(".DS_Store"))
        #expect(AgentPaths.recording(directory).workshop == nil)
    }

    @Test("過去錄音：還沒搬進 Library 時，兩個路徑都不能複製，也不提示命名")
    func notPublished() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp, liveTranscript: false, workshop: ["Workshop"])
        let paths = AgentPaths.finished(directory, meta: meta(steps: ["blocks", "transcript", "audio"]))
        #expect(paths == AgentPaths())
    }

    @Test("過去錄音：搬進 Library 但還沒有標題（摘要做好時會改名）時不能複製，並提示要先命名；只有空白也算沒有標題")
    func untitled() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp, liveTranscript: false, workshop: ["Workshop"])
        #expect(AgentPaths.finished(directory, meta: meta(title: "")) == AgentPaths(waitsForTitle: true))
        #expect(AgentPaths.finished(directory, meta: meta(title: " \n ")) == AgentPaths(waitsForTitle: true))
    }

    @Test("過去錄音：搬進 Library 而且有標題，就可以複製 transcript.md 的路徑；教材要下載過才有")
    func published() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp, liveTranscript: false)
        #expect(
            AgentPaths.finished(directory, meta: meta()) == AgentPaths(transcript: directory.transcriptURL, workshop: nil))
        try FileManager.default.createDirectory(
            at: directory.workshopURL.appendingPathComponent("Workshop", isDirectory: true), withIntermediateDirectories: true)
        #expect(
            AgentPaths.finished(directory, meta: meta())
                == AgentPaths(transcript: directory.transcriptURL, workshop: directory.workshopURL))
    }

    @Test("過去錄音：transcript.md 不存在（例如逐字稿沒有做出來）時，不能複製逐字稿路徑")
    func missingTranscript() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try session(in: tmp, liveTranscript: false, transcript: false)
        #expect(AgentPaths.finished(directory, meta: meta()).transcript == nil)
    }
}
