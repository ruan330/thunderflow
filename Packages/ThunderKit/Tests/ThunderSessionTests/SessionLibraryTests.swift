import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

private let taipei = TimeZone(identifier: "Asia/Taipei") ?? .gmt

@Suite("SessionLibrary：資料夾命名與場次清單")
struct SessionLibraryTests {
    private func meta(_ title: String) -> SessionMeta {
        SessionMeta(title: title, startedAt: Finished.startedAt)
    }

    /// 在 `root` 底下建立一個只有 `session.json` 的場次資料夾。
    private func makeFolder(
        _ name: String, in root: URL, title: String, startedAt: Date, state: SessionState = .complete
    ) throws -> SessionMeta {
        let meta = SessionMeta(title: title, startedAt: startedAt, state: state)
        let directory = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: directory.hiddenDirectoryURL, withIntermediateDirectories: true)
        try directory.saveMeta(meta)
        return meta
    }

    @Test("資料夾名稱是當地的開始時間加標題；沒有標題時是「未命名」")
    func folderName() throws {
        #expect(
            SessionLibrary.folderName(for: meta("Building Agents with Bedrock"), timeZone: taipei)
                == "2026-12-02 1030 Building Agents with Bedrock")
        #expect(SessionLibrary.folderName(for: meta(""), timeZone: taipei) == "2026-12-02 1030 未命名")
        #expect(SessionLibrary.folderName(for: meta(" \n "), timeZone: taipei) == "2026-12-02 1030 未命名")
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(SessionLibrary.folderName(for: meta("Keynote"), timeZone: losAngeles) == "2026-12-01 1830 Keynote")
        // 不指定時用系統的時區
        #expect(
            SessionLibrary.folderName(for: meta("Keynote"))
                == SessionLibrary.folderName(for: meta("Keynote"), timeZone: .current))
        #expect(SessionLibrary.folderName(for: meta("Keynote")).hasSuffix(" Keynote"))
    }

    @Test(
        "不能當檔名的字元（/、:、控制字元、換行）換成空白，連續的空白收成一個",
        arguments: [
            ("AI/ML: What's \"Next\"?", "AI ML What's \"Next\"?"),
            ("Part 1\tand\n2\u{0}", "Part 1 and 2"),
            ("  Hello    world  ", "Hello world"),
            ("///", "未命名"),
            ("機器學習導論：第 3 講", "機器學習導論：第 3 講"),
        ] as [(String, String)])
    func sanitisesTitles(title: String, expected: String) {
        #expect(SessionLibrary.folderName(for: meta(title), timeZone: taipei) == "2026-12-02 1030 " + expected)
    }

    @Test("標題最多取 80 個字元，截斷後不以空白結尾；再長的標題也建得出資料夾（包含重名時的序號）")
    func limitsTitleLength() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        #expect(
            SessionLibrary.folderName(for: meta(String(repeating: "講", count: 100)), timeZone: taipei)
                == "2026-12-02 1030 " + String(repeating: "講", count: 80))
        #expect(
            SessionLibrary.folderName(for: meta(String(repeating: "a", count: 79) + " bcd"), timeZone: taipei)
                == "2026-12-02 1030 " + String(repeating: "a", count: 79))

        // 檔名有長度上限（以編碼單位計算）：一個字元占很多單位的標題要再縮短
        for unit in ["講", "👨‍👩‍👧‍👦", "é"] {
            let name = SessionLibrary.folderName(for: meta(String(repeating: unit, count: 100)), timeZone: taipei)
            #expect(name.count <= 16 + 80)
            #expect(name.hasPrefix("2026-12-02 1030 " + unit))
            let first = SessionLibrary.availableURL(named: name, in: tmp.url)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            let second = SessionLibrary.availableURL(named: name, in: tmp.url)
            #expect(second.lastPathComponent == name + " 2")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        }
    }

    @Test("availableURL：沒人用就用原名，被占用時依序加上 2、3……")
    func availableURL() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let root = tmp.url.appendingPathComponent("Library", isDirectory: true)

        // Library 還不存在
        #expect(SessionLibrary.availableURL(named: "Talk", in: root).path == root.path + "/Talk")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Talk"), withIntermediateDirectories: true)
        #expect(SessionLibrary.availableURL(named: "Talk", in: root).path == root.path + "/Talk 2")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Talk 2"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Talk 3"))  // 檔案也算占用
        #expect(SessionLibrary.availableURL(named: "Talk", in: root).path == root.path + "/Talk 4")
        #expect(SessionLibrary.availableURL(named: "Other", in: root).path == root.path + "/Other")
    }

    @Test("清單由新到舊，只讀 session.json；壞掉的資料夾與不相干的東西都略過；Library 不存在時是空的")
    func listsSessionsNewestFirst() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let root = tmp.url.appendingPathComponent("Library", isDirectory: true)
        #expect(SessionLibrary.list(root: root).isEmpty)

        let day = 86_400.0
        let oldest = try makeFolder("c oldest", in: root, title: "最舊", startedAt: Finished.startedAt)
        let newest = try makeFolder(
            "a newest", in: root, title: "最新", startedAt: Finished.startedAt + 2 * day, state: .finalizing)
        let middle = try makeFolder("b middle", in: root, title: "中間", startedAt: Finished.startedAt + day)

        // 壞掉的資料夾與不相干的東西
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty folder"), withIntermediateDirectories: true)
        for (name, content) in [
            ("garbage", "not json"),
            ("truncated", "{\"schemaVersion\":1,\"id\":\"6F1C0E0A-3B4D"),
            (
                "from the future",
                "{\"schemaVersion\":99,\"id\":\"6F1C0E0A-3B4D-4C5E-8F90-123456789ABC\",\"startedAt\":\"2026-11-30T00:53:20Z\",\"state\":\"complete\"}"
            ),
        ] {
            let broken = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: broken.hiddenDirectoryURL, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: broken.metaURL)
        }
        try Data("hi".utf8).write(to: root.appendingPathComponent("notes.txt"))
        _ = try makeFolder(".hidden", in: root, title: "名稱以點開頭的暫存資料夾", startedAt: Finished.startedAt + 3 * day)

        let items = SessionLibrary.list(root: root)

        #expect(items.map(\.meta) == [newest, middle, oldest])
        #expect(items.map(\.id) == [newest.id, middle.id, oldest.id])
        #expect(items.map(\.directory.url.lastPathComponent) == ["a newest", "b middle", "c oldest"])
        #expect(items.map(\.meta.state) == [.finalizing, .complete, .complete])
    }

    @Test("狀態只靠資料夾重建（不變條件 3）：使用者在 Finder 裡改了資料夾名稱，場次照樣找得到，用 id 識別")
    func rebuildsFromFolders() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let root = tmp.url.appendingPathComponent("Library", isDirectory: true)
        let meta = try makeFolder("2026-12-02 1030 Keynote", in: root, title: "Keynote", startedAt: Finished.startedAt)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent("2026-12-02 1030 Keynote"), to: root.appendingPathComponent("我自己取的名字"))

        let items = SessionLibrary.list(root: root)
        #expect(items.map(\.id) == [meta.id])
        #expect(items.map(\.meta) == [meta])
        #expect(items.map(\.directory.url.lastPathComponent) == ["我自己取的名字"])
    }
}
