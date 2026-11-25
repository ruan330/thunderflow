import Foundation
import Testing
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 假的 workshop-archive：依網址裡的關鍵字演出不同的結果，並把收到的參數一行一個寫進 `args.txt`。
private let fakeTool = #"""
    #!/bin/sh
    here=$(cd "$(dirname "$0")" && pwd)
    printf '%s\n' "$@" > "$here/args.txt"
    out=""; url=""; prev=""; rest=0
    for arg in "$@"; do
      if [ "$rest" = 1 ]; then url="$arg"; continue; fi
      if [ "$arg" = "--" ]; then rest=1; continue; fi
      if [ "$prev" = "--out" ]; then out="$arg"; fi
      prev="$arg"
    done
    case "$url" in
      *usage*) echo "workshop-archive: error: unrecognized arguments" >&2; exit 2 ;;
      *slow*) touch "$here/started"; sleep 30 ;;
      *moved*) touch "$here/started"; while [ ! -e "$here/go" ]; do sleep 0.05; done ;;
    esac
    mkdir -p "$out/markdown" || exit 1
    echo "# Workshop" > "$out/markdown/README.md"
    echo '{"event":"phase","phase":"discover","counts":{"page":{"planned":0,"saved":0}}}' >&2
    echo '{"event":"transfer","counts":{"page":{"planned":22,"saved":10}}}' >&2
    case "$url" in
      *auth*)
        printf '{"status":"failed","failures":[{"category":"access_denied","reason":"HTTP 403"}]}' > "$out/receipt.json"
        echo '{"status":"failed"}'; exit 1 ;;
      *partial*)
        printf '{"status":"partial","title":"Building with Generative AI on AWS"}' > "$out/receipt.json"
        echo '{"status":"partial"}'; exit 2 ;;
      *notitle*)
        printf '{"status":"complete"}' > "$out/receipt.json"
        echo '{"status":"complete"}'; exit 0 ;;
      *)
        printf '{"status":"complete","title":"Building with Generative AI on AWS"}' > "$out/receipt.json"
        echo '{"status":"complete"}'; exit 0 ;;
    esac
    """#

/// 測試用的環境：假工具、暫存資料夾、一個場次資料夾。
private struct Bench {
    let tmp: TemporaryDirectory
    let tool: URL
    let staging: URL
    let session: SessionDirectory

    init() throws {
        tmp = try TemporaryDirectory()
        let bin = tmp.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        tool = bin.appendingPathComponent("workshop-archive")
        try fakeTool.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        staging = tmp.url.appendingPathComponent("Downloads", isDirectory: true)
        session = SessionDirectory(url: tmp.url.appendingPathComponent("Working/session", isDirectory: true))
        try session.create()
    }

    var downloader: WorkshopDownloader {
        WorkshopDownloader(tool: tool, stagingRoot: staging, placementTimeout: .milliseconds(300))
    }

    func marker(_ name: String) -> URL { tool.deletingLastPathComponent().appendingPathComponent(name) }

    /// 假工具收到的參數。
    var arguments: [String] {
        ((try? String(contentsOf: marker("args.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// 暫存資料夾裡留下的東西（不存在算空的）。
    var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] }

    func materials(in directory: SessionDirectory) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.workshopURL.path)) ?? []).sorted()
    }
}

private let title = "Building with Generative AI on AWS"

@Suite("工作坊教材的下載：呼叫 workshop-archive，完成後放進這一場（D34）", .timeLimit(.minutes(1)))
struct WorkshopDownloaderTests {
    @Test("完成：教材放進這一場的 workshop/<標題>/，暫存資料夾清掉")
    func complete() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let outcome = try await bench.downloader.download("https://example.com/complete", into: { session })
        let folder = session.workshopURL.appendingPathComponent(title, isDirectory: true)
        #expect(outcome == .complete(folder))
        #expect(fileExists(folder.appendingPathComponent("markdown/README.md")))
        #expect(bench.leftovers.isEmpty)
    }

    @Test("呼叫的指令：capture、--out 新的暫存資料夾、--no-index、進度用 JSON Lines，網址放在 -- 之後")
    func arguments() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let address = "https://catalog.workshops.aws/building-gen-ai-apps/en-US"
        _ = try await bench.downloader.download(address, into: { session })
        let arguments = bench.arguments
        try #require(arguments.count == 8)
        #expect(Array(arguments[0...1]) == ["capture", "--out"])
        #expect(arguments[2].hasPrefix(bench.staging.path + "/"))
        #expect(Array(arguments[3...]) == ["--no-index", "--progress-format", "jsonl", "--", address])
    }

    @Test("部分完成（結束代碼 2）：教材照樣放進去，結果是部分完成")
    func partial() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let outcome = try await bench.downloader.download("https://example.com/partial", into: { session })
        #expect(outcome == .partial(session.workshopURL.appendingPathComponent(title, isDirectory: true)))
        #expect(bench.leftovers.isEmpty)
    }

    @Test("失敗（例如需要登入）：什麼都不放，暫存資料夾清掉，說明原因")
    func failed() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        await #expect(throws: WorkshopDownloadError.failed("需要登入或沒有權限：這個工具只抓公開的教材")) {
            try await bench.downloader.download("https://example.com/auth", into: { session })
        }
        #expect(!fileExists(session.workshopURL))
        #expect(bench.leftovers.isEmpty)
    }

    @Test("結束代碼 2 但沒有產生資料夾（工具的用法錯誤）時算失敗")
    func usageError() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        await #expect(throws: WorkshopDownloadError.self) {
            try await bench.downloader.download("https://example.com/usage", into: { session })
        }
        #expect(!fileExists(session.workshopURL))
        #expect(bench.leftovers.isEmpty)
    }

    @Test("找不到 workshop-archive 時直接失敗，什麼都不建立")
    func toolMissing() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let missing = bench.tmp.url.appendingPathComponent("nowhere/workshop-archive")
        let downloader = WorkshopDownloader(tool: missing, stagingRoot: bench.staging)
        #expect(!downloader.isToolInstalled)
        #expect(bench.downloader.isToolInstalled)
        await #expect(throws: WorkshopDownloadError.toolMissing(missing)) {
            try await downloader.download("https://example.com/complete", into: { session })
        }
        #expect(!fileExists(bench.staging))
    }

    @Test("網址不是 https:// 開頭時不呼叫工具（也擋掉看起來像選項的字串）")
    func invalidAddress() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        for address in ["", "  ", "--out=/tmp/x", "http://example.com/complete", "ftp://example.com", "example.com"] {
            await #expect(throws: WorkshopDownloadError.invalidAddress) {
                try await bench.downloader.download(address, into: { session })
            }
        }
        #expect(!fileExists(bench.marker("args.txt")))
    }

    @Test("前後的空白去掉之後才交給工具")
    func trimmedAddress() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        _ = try await bench.downloader.download("  https://example.com/complete \n", into: { session })
        #expect(bench.arguments.last == "https://example.com/complete")
    }

    @Test("同一個標題下載兩次：兩份都保留，第二份加序號")
    func keepsEveryDownload() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        _ = try await bench.downloader.download("https://example.com/complete", into: { session })
        let second = try await bench.downloader.download("https://example.com/complete", into: { session })
        #expect(second.folder.lastPathComponent == "\(title) 2")
        #expect(bench.materials(in: session) == [title, "\(title) 2"])
    }

    @Test("沒有標題時用網址裡的名稱命名（略過最後的語言代碼）")
    func nameFromAddress() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let outcome = try await bench.downloader.download(
            "https://catalog.workshops.aws/notitle-workshop/en-US", into: { session })
        #expect(outcome.folder.lastPathComponent == "notitle-workshop")
    }

    @Test("下載途中這一場搬家（例如搬進 Library）：教材放進它下載完時所在的資料夾")
    func sessionMovedDuringDownload() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let moved = SessionDirectory(url: bench.tmp.url.appendingPathComponent("Library/2026-12-01 1030 GameDay", isDirectory: true))
        let location = LockedValue(bench.session)
        let downloader = bench.downloader
        let task = Task { try await downloader.download("https://example.com/moved", into: { location.withValue { $0 } }) }
        #expect(await waitUntil { fileExists(bench.marker("started")) })
        try FileManager.default.createDirectory(
            at: moved.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bench.session.url, to: moved.url)
        location.withValue { $0 = moved }
        FileManager.default.createFile(atPath: bench.marker("go").path, contents: nil)
        let outcome = try await withDeadline(.seconds(10)) { try await task.value }
        #expect(outcome == .complete(moved.workshopURL.appendingPathComponent(title, isDirectory: true)))
        #expect(bench.materials(in: moved) == [title])
    }

    @Test("下載完找不到這一場（例如已經刪除）時算失敗，暫存資料夾清掉")
    func sessionGone() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        await #expect(throws: WorkshopDownloadError.sessionUnavailable) {
            try await bench.downloader.download("https://example.com/complete", into: { nil })
        }
        #expect(bench.leftovers.isEmpty)
    }

    @Test("取消下載：結束 workshop-archive，什麼都不放，暫存資料夾清掉")
    func cancel() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let downloader = bench.downloader
        let task = Task { try await downloader.download("https://example.com/slow", into: { session }) }
        #expect(await waitUntil { fileExists(bench.marker("started")) })
        task.cancel()
        let result = try await withDeadline(.seconds(5)) { await task.result }
        #expect(throws: WorkshopDownloadError.cancelled) { try result.get() }
        #expect(!fileExists(session.workshopURL))
        #expect(bench.leftovers.isEmpty)
    }

    @Test("進度：讀得到 workshop-archive 回報的頁數")
    func progress() async throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let session = bench.session
        let reports = LockedValue<[WorkshopDownloadProgress]>([])
        _ = try await bench.downloader.download(
            "https://example.com/complete", into: { session }, progress: { report in reports.withValue { $0.append(report) } })
        #expect(reports.withValue { $0 }.last == WorkshopDownloadProgress(savedPages: 10, plannedPages: 22))
    }

    @Test("App 啟動時清掉暫存資料夾裡上次留下的東西")
    func leftovers() throws {
        let bench = try Bench()
        defer { bench.tmp.remove() }
        let old = bench.staging.appendingPathComponent("0A1B/archive", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        WorkshopDownloader.removeLeftovers(in: bench.staging)
        #expect(bench.leftovers.isEmpty)
    }
}
