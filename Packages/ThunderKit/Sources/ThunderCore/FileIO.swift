import Foundation

/// 直接呼叫 POSIX 的檔案操作。日誌與 `session.json` 都不經過程式自己的緩衝區，
/// 寫入一返回資料就已經交給作業系統，程式被強制結束也不會遺失。
enum FileIO {
    /// 把 `bytes` 全部寫進 `descriptor`。被訊號中斷時重試；作業系統只寫了一部分時接著寫完。
    static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32, path: String) throws {
        guard var cursor = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let written = write(descriptor, cursor, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                throw posixError(errno, path: path)
            }
            cursor += written
            remaining -= written
        }
    }

    /// 原子寫入：先寫進同一個資料夾裡的暫存檔並 fsync，再用 rename(2) 取代原檔。
    ///
    /// 讀的人（以及任何時間點被強制結束的程序）只會看到舊的完整內容或新的完整內容。
    /// 成功之後不會留下暫存檔；寫到一半失敗會刪掉暫存檔。只有程序在這幾步之間被殺掉，
    /// 才可能留下一個以「.」開頭、以「.tmp」結尾的暫存檔，它不會被當成資料讀取。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let path = url.path
        let temporaryPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError(errno, path: temporaryPath) }
        var renamed = false
        defer { if !renamed { unlink(temporaryPath) } }
        do {
            try data.withUnsafeBytes { try writeAll($0, to: descriptor, path: temporaryPath) }
            // 先把內容送到磁碟再 rename，斷電時才不會留下改了名字、內容卻是空的檔
            guard fsync(descriptor) == 0 else { throw posixError(errno, path: temporaryPath) }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw posixError(errno, path: temporaryPath) }
        guard rename(temporaryPath, path) == 0 else { throw posixError(errno, path: path) }
        renamed = true
    }

    static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(path)：\(String(cString: strerror(code)))"])
    }
}
