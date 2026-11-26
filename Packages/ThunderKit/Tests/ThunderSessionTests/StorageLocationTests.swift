import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// DESIGN.md 5.9、5.10 節（D37）：Library 預設放在 iCloud 雲碟裡，手機的收件匣在 App 自己的 iCloud 空間裡，
/// 使用者兩邊都不用選資料夾。
@Suite("儲存位置：Library 預設在 iCloud 雲碟，收件匣在 App 自己的 iCloud 空間（D37）")
struct StorageLocationTests {
    private func iCloudDrive(in home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private func documentsLibrary(in home: URL) -> URL {
        home.appendingPathComponent("Documents/ThunderFlow", isDirectory: true)
    }

    private func path(_ url: URL) -> String { url.standardizedFileURL.path }

    @Test("這台 Mac 有 iCloud 雲碟時，Library 預設是 iCloud 雲碟裡的「ThunderFlow」")
    func defaultsToICloudDrive() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let drive = iCloudDrive(in: home.url)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)

        #expect(path(SessionLibrary.defaultRoot(home: home.url)) == path(drive.appendingPathComponent("ThunderFlow")))
    }

    @Test("沒有 iCloud 雲碟（沒登入 iCloud、或關掉 iCloud 雲碟）時，Library 預設是「文件」裡的「ThunderFlow」")
    func fallsBackToDocuments() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }

        #expect(path(SessionLibrary.defaultRoot(home: home.url)) == path(documentsLibrary(in: home.url)))
    }

    @Test("舊的預設位置（「文件」裡的 ThunderFlow）已經有場次時繼續用它：不替使用者搬檔案，過去錄音也不會突然變空")
    func keepsLegacyLibraryWithSessions() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: iCloudDrive(in: home.url), withIntermediateDirectories: true)
        let legacy = documentsLibrary(in: home.url)
        let session = SessionDirectory(url: legacy.appendingPathComponent("2026-12-02 1030 Keynote", isDirectory: true))
        try FileManager.default.createDirectory(at: session.hiddenDirectoryURL, withIntermediateDirectories: true)
        try session.saveMeta(SessionMeta(title: "Keynote", startedAt: Finished.startedAt))

        #expect(path(SessionLibrary.defaultRoot(home: home.url)) == path(legacy))
    }

    @Test("舊的預設位置只是沒有場次的資料夾（例如按過「在 Finder 中顯示」）時，照樣用 iCloud 雲碟")
    func ignoresLegacyFolderWithoutSessions() throws {
        let home = try TemporaryDirectory()
        defer { home.remove() }
        let drive = iCloudDrive(in: home.url)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let legacy = documentsLibrary(in: home.url)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacy.appendingPathComponent(".DS_Store"))

        #expect(path(SessionLibrary.defaultRoot(home: home.url)) == path(drive.appendingPathComponent("ThunderFlow")))
    }

    @Test("收件匣在 App 的 iCloud container 裡（不在 Documents，看不到）；Mac 上的路徑和 iPhone 用的是同一個位置")
    func inboxLocation() {
        #expect(SessionHandoff.containerIdentifier == "iCloud.io.github.ruan330.thunderflow")
        let container = URL(
            fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~io~github~ruan330~thunderflow",
            isDirectory: true)
        #expect(SessionHandoff.inbox(inContainer: container).path == container.path + "/Inbox")

        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(
            SessionHandoff.macInbox(home: home).path
                == "/Users/someone/Library/Mobile Documents/iCloud~io~github~ruan330~thunderflow/Inbox")
        // 收件匣不在預設的 Library 裡面，也不是它（SessionInbox 會拒絕這種設定）
        #expect(SessionInbox.problem(inbox: SessionHandoff.macInbox(home: home), library: SessionLibrary.defaultRoot(home: home)) == nil)
    }

    @Test("container 的識別碼和 iPhone 版的 entitlements 一樣：不一樣時手機會交到 Mac 看不到的地方")
    func matchesPhoneEntitlements() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // ThunderSessionTests
            .deletingLastPathComponent().deletingLastPathComponent()  // ThunderKit
            .deletingLastPathComponent().deletingLastPathComponent()  // repo
        let file = root.appendingPathComponent("iOS/ThunderFlowPhone.entitlements")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        for key in ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.ubiquity-container-identifiers"] {
            #expect(plist[key] as? [String] == [SessionHandoff.containerIdentifier], "\(key)")
        }
        #expect(plist["com.apple.developer.icloud-services"] as? [String] == ["CloudDocuments"])
    }
}
