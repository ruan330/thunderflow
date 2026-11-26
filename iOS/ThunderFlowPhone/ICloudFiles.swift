import Foundation

/// 讀 App 的 iCloud 空間裡的檔案（DESIGN.md 5.10 節，D38）。
///
/// 手機上的 iCloud 檔案要用的時候才下載：協調讀取（`NSFileCoordinator`）會先把還沒下載的檔案下載下來，
/// 再讓我們讀。這會等網路，所以放在 GCD 的佇列上做（不占 Swift concurrency 的執行緒），並設時限：
/// 時間到就取消，回報逾時。
enum ICloudFiles {
    enum Outcome: Sendable, Equatable {
        /// 檔案在手機上了，可以讀。
        case ready
        /// 沒有這個檔案。
        case missing
        /// 時間到了還沒下載好（多半是沒有網路）。
        case timedOut
        /// 其他錯誤（附上說明）。
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "ThunderFlow.iCloud", qos: .utility, attributes: .concurrent)

    /// 在背景的佇列上做一件會等待的事（讀 iCloud、列資料夾）。
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// 開始下載（不等）：一次要很多個檔案時先全部叫系統開始下載，再一個一個等。
    static func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// 確定 `url` 已經在手機上：還沒下載就下載，最多等 `timeout` 秒。會等待：只在 `run` 裡面呼叫。
    static func download(_ url: URL, timeout: TimeInterval) -> Outcome {
        requestDownload(url)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let timer = DispatchWorkItem { coordinator.cancel() }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        var coordinationError: NSError?
        var readable = false
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { local in
            readable = FileManager.default.isReadableFile(atPath: local.path)
        }
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == CocoaError.userCancelled.rawValue {
                return .timedOut
            }
            return .failed(coordinationError.localizedDescription)
        }
        return readable ? .ready : .missing
    }
}
