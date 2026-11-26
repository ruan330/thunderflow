#if os(macOS)
// 工作坊教材的下載只在 Mac 上（D34）：要執行外部工具（Process）。
import Foundation
import ThunderCore

/// 下載好的教材放在哪裡。
public enum WorkshopDownloadOutcome: Sendable, Equatable {
    /// 完成：教材在這個資料夾（`<場次>/workshop/<標題>/`）。
    case complete(URL)
    /// 部分完成：有些資源抓不到（例如外部參考網頁），教材照樣能用。
    case partial(URL)

    public var folder: URL {
        switch self {
        case .complete(let url), .partial(let url): url
        }
    }
}

public enum WorkshopDownloadError: Error, Equatable {
    /// 網址不是 `https://` 開頭（也擋掉看起來像選項的字串）。
    case invalidAddress
    /// 找不到 workshop-archive。
    case toolMissing(URL)
    /// 下載失敗，附上給人看的原因（例如需要登入）。
    case failed(String)
    /// 下載好了，但找不到這一場（例如已經刪除），教材沒有地方放。
    case sessionUnavailable
    case cancelled
}

extension WorkshopDownloadError: CustomStringConvertible, LocalizedError {
    /// 給人看的說明（句尾不加句號）。
    public var description: String {
        switch self {
        case .invalidAddress: "網址要以 https:// 開頭"
        case .toolMissing(let url): "找不到 workshop-archive（\(url.path)）"
        case .failed(let reason): reason
        case .sessionUnavailable: "找不到這一場（可能已經刪除），教材沒有放進去"
        case .cancelled: "已取消"
        }
    }

    public var errorDescription: String? { description }
}

/// 下載的進度：workshop-archive 回報的頁數。
public struct WorkshopDownloadProgress: Sendable, Equatable {
    public var savedPages: Int
    public var plannedPages: Int

    public init(savedPages: Int, plannedPages: Int) {
        self.savedPages = savedPages
        self.plannedPages = plannedPages
    }
}

/// 工作坊教材的下載（DESIGN.md 5.9 節，D34）：呼叫外部工具 workshop-archive 下載到暫存資料夾，
/// 完成後才搬進這一場**當下所在**的資料夾的 `workshop/<標題>/`。
public struct WorkshopDownloader: Sendable {
    /// workshop-archive 安裝程式的預設位置。
    public static var defaultTool: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/workshop-archive")
    }

    public let tool: URL
    /// 暫存資料夾的上層（工作目錄旁的 `Downloads/`）。每次下載用一個子資料夾，結束時刪掉。
    public let stagingRoot: URL
    /// 下載好之後，找不到這一場（例如正在搬進 Library）時最多再等多久。
    public let placementTimeout: Duration

    public init(tool: URL = WorkshopDownloader.defaultTool, stagingRoot: URL, placementTimeout: Duration = .seconds(10)) {
        self.tool = tool
        self.stagingRoot = stagingRoot
        self.placementTimeout = placementTimeout
    }

    /// workshop-archive 在不在、能不能執行。
    public var isToolInstalled: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

    /// 下載 `address` 的教材，完成後搬進 `locate()` 回傳的場次資料夾的 `workshop/`。
    ///
    /// `locate` 在下載完之後才呼叫，所以下載途中場次搬進 Library、自動改名都不影響；
    /// 找不到（例如正在搬家）時，最多再等 `placementTimeout`。失敗、取消時不放任何東西，暫存資料夾也刪掉。
    ///
    /// 和 workshop-archive 的約定只有這幾件事（DESIGN.md 5.9 節）：`capture`、`--out`（新的資料夾）、`--no-index`、
    /// 結束代碼（0 完成、2 部分完成、其他是失敗）與 `receipt.json` 的 `title`。進度（`--progress-format jsonl`）讀不懂就不顯示。
    public func download(
        _ address: String,
        into locate: @escaping @Sendable () -> SessionDirectory?,
        progress: (@Sendable (WorkshopDownloadProgress) -> Void)? = nil
    ) async throws -> WorkshopDownloadOutcome {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAcceptable(address) else { throw WorkshopDownloadError.invalidAddress }
        guard isToolInstalled else { throw WorkshopDownloadError.toolMissing(tool) }
        guard !Task.isCancelled else { throw WorkshopDownloadError.cancelled }

        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("archive", isDirectory: true)
        let status = try await run(
            ["capture", "--out", archive.path, "--no-index", "--progress-format", "jsonl", "--", address],
            in: staging, progress: progress)
        guard !Task.isCancelled else { throw WorkshopDownloadError.cancelled }

        let receipt = Self.receipt(in: archive)
        let succeeded =
            (status == 0 || status == 2) && FileManager.default.fileExists(atPath: archive.path)
            && receipt?["status"] as? String != "failed"
        guard succeeded else { throw WorkshopDownloadError.failed(Self.reason(receipt, status: status)) }
        let name = Self.folderName(title: receipt?["title"] as? String, address: address)
        let folder = try await place(archive, named: name, locate: locate)
        return status == 0 ? .complete(folder) : .partial(folder)
    }

    /// 刪掉暫存資料夾裡上次留下的東西（App 當掉或被強制結束時沒刪到的）。App 啟動時呼叫。
    public static func removeLeftovers(in stagingRoot: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        for name in names { try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name)) }
    }

    // MARK: 網址與名稱

    /// 只接受 `https://` 開頭、有主機名稱、沒有空白的網址：看起來像選項的字串（`--out=…`）也就進不來。
    static func isAcceptable(_ address: String) -> Bool {
        guard address.lowercased().hasPrefix("https://"), !address.contains(where: \.isWhitespace),
            let url = URL(string: address), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// 教材資料夾的名稱：`receipt.json` 的標題；沒有標題時用網址路徑的最後一段（略過語言代碼，例如 en-US），再沒有就用主機名稱。
    static func folderName(title: String?, address: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SessionLibrary.fileNameTitle(title)
        }
        guard let url = URL(string: address) else { return SessionLibrary.fileNameTitle("") }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty && $0.wholeMatch(of: /[a-z]{2}-[A-Z]{2}/) == nil }
        return SessionLibrary.fileNameTitle(parts.last ?? url.host ?? "")
    }

    /// 失敗的原因（給人看）：先看 `receipt.json` 記下的第一個失敗。
    static func reason(_ receipt: [String: Any]?, status: Int32) -> String {
        let failure = (receipt?["failures"] as? [[String: Any]])?.first
        let category = failure?["category"] as? String
        let detail = failure?["reason"] as? String ?? ""
        if category == "access_denied" || detail.localizedCaseInsensitiveContains("authentication") {
            return "需要登入或沒有權限：這個工具只抓公開的教材"
        }
        switch category {
        case "invalid_url", "unsafe_host": return "這個網址不能下載：只接受公開的 https 網址"
        case "network_error", "tls_error", "host_cooldown": return "連不上教材網站"
        default: return "下載失敗（workshop-archive 結束代碼 \(status)）"
        }
    }

    private static func receipt(in archive: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: archive.appendingPathComponent("receipt.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: 執行工具

    /// 執行 workshop-archive，回傳結束代碼。標準輸出與錯誤都寫進暫存資料夾裡的檔案（不用管道，不會互相卡住），
    /// 錯誤輸出（進度）邊寫邊讀。被取消時先請它結束（SIGTERM），5 秒還沒結束就強制結束。
    private func run(
        _ arguments: [String], in staging: URL, progress: (@Sendable (WorkshopDownloadProgress) -> Void)?
    ) async throws -> Int32 {
        let outputURL = staging.appendingPathComponent("result.json")
        let progressURL = staging.appendingPathComponent("progress.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: progressURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: progressURL)
        defer {
            try? output.close()
            try? errors.close()
        }
        let tool = RunningTool(executable: self.tool, arguments: arguments, output: output, errors: errors)
        let reader = ProgressReader(url: progressURL, report: progress)
        let polling = Task {
            while !Task.isCancelled {
                reader.readNew()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { polling.cancel() }
        let status = try await withTaskCancellationHandler {
            try await tool.run()
        } onCancel: {
            tool.cancel()
        }
        reader.readNew()
        return status
    }

    // MARK: 放進這一場

    /// 把下載好的教材搬進這一場的 `workshop/<名稱>/`（名稱被占用時加序號）。
    ///
    /// 只在場次資料夾還在時建立 `workshop/`：場次剛好搬走時，不會在舊的位置留下空殼，而是重新找一次。
    private func place(_ archive: URL, named name: String, locate: @Sendable () -> SessionDirectory?) async throws -> URL {
        let clock = ContinuousClock()
        let deadline = clock.now + placementTimeout
        let fileManager = FileManager.default
        while true {
            guard !Task.isCancelled else { throw WorkshopDownloadError.cancelled }
            if let session = locate(), fileManager.fileExists(atPath: session.url.path) {
                let parent = session.workshopURL
                if !fileManager.fileExists(atPath: parent.path) {
                    try? fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
                }
                let target = SessionLibrary.availableURL(named: name, in: parent)
                if (try? fileManager.moveItem(at: archive, to: target)) != nil { return target }
            }
            guard clock.now < deadline else { throw WorkshopDownloadError.sessionUnavailable }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// 一次 workshop-archive 的執行。取消可能發生在啟動之前、之中、之後，所以狀態放在鎖裡。
private final class RunningTool: @unchecked Sendable {
    // @unchecked Sendable：`Process` 只在 `lock` 裡啟動與結束；其餘是建立後不再改變的常數。
    private let process = Process()
    private let lock = NSLock()
    private var launched = false
    private var cancelled = false

    init(executable: URL, arguments: [String], output: FileHandle, errors: FileHandle) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    /// 執行到結束，回傳結束代碼。啟動之前就被取消時丟出 `cancelled`。
    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else {
                continuation.resume(throwing: WorkshopDownloadError.cancelled)
                return
            }
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                launched = true
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: WorkshopDownloadError.failed("無法執行 workshop-archive：\(error.localizedDescription)"))
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        guard launched, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// 邊寫邊讀 workshop-archive 的進度（JSON Lines），讀到頁數就回報。讀不懂的行略過。
private final class ProgressReader: @unchecked Sendable {
    // @unchecked Sendable：可變的狀態只在 `lock` 裡讀寫。
    private let url: URL
    private let report: (@Sendable (WorkshopDownloadProgress) -> Void)?
    private let lock = NSLock()
    private var offset: UInt64 = 0
    private var pending = Data()
    private var last: WorkshopDownloadProgress?

    init(url: URL, report: (@Sendable (WorkshopDownloadProgress) -> Void)?) {
        self.url = url
        self.report = report
    }

    func readNew() {
        guard report != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let progress = Self.progress(in: Data(line)), progress != last else { continue }
            last = progress
            report?(progress)
        }
    }

    /// `{"counts":{"page":{"planned":22,"saved":10}}}` 這樣的一行。
    private static func progress(in line: Data) -> WorkshopDownloadProgress? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let counts = object["counts"] as? [String: Any], let page = counts["page"] as? [String: Any],
            let planned = page["planned"] as? Int, let saved = page["saved"] as? Int
        else { return nil }
        return WorkshopDownloadProgress(savedPages: saved, plannedPages: planned)
    }
}
#endif
