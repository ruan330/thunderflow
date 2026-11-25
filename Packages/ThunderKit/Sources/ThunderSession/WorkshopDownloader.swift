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
    /// `locate` 在下載完之後才呼叫，所以下載途中場次搬進 Library、自動改名都不影響。
    /// 失敗、取消時不放任何東西，暫存資料夾也刪掉。
    public func download(
        _ address: String,
        into locate: @escaping @Sendable () -> SessionDirectory?,
        progress: (@Sendable (WorkshopDownloadProgress) -> Void)? = nil
    ) async throws -> WorkshopDownloadOutcome {
        throw WorkshopDownloadError.failed("還沒有實作")
    }

    /// 刪掉暫存資料夾裡上次留下的東西（App 當掉或被強制結束時沒刪到的）。App 啟動時呼叫。
    public static func removeLeftovers(in stagingRoot: URL) {}
}
