import Foundation
import Synchronization

/// 一個場次資料夾的獨占鎖：同一時間只有一方可以處理這個場次——正在錄音的場次，或正在做結束處理的那一方。
///
/// 為什麼需要：正在錄音的場次和「上次沒有正常結束」的場次，`session.json` 的狀態都是 recording。
/// App 啟動之後會把後者復原並做完結束處理；分不出來的話，正在錄的場次會被拿去收尾，之後的聲音就遺失了
/// （多開一個視窗、多開一個 App 都會發生）。
///
/// 做法是用 `flock(2)` 鎖住資料夾本身：
/// - 不在資料夾裡留下任何檔案。
/// - 資料夾在同一個磁碟上改名或搬移時，鎖跟著走；搬到別的磁碟（複製後刪除）時不會，要在新的位置重新鎖。
/// - 持有鎖的程式結束（包括當機、被強制結束）時由系統釋放，所以真正中斷的場次一定找得回來。
/// - 鎖屬於這一次開啟的資料夾，所以同一個程式裡的其他地方也拿不到。
/// - 放掉時先明確解鎖（`LOCK_UN`）再關閉描述子：別的執行緒啟動子程式（例如 workshop-archive）的那一瞬間，
///   子程式會拿到描述子的複本（close-on-exec 要等它 exec 才關掉）。只靠關閉的話，要等複本也關掉鎖才放開，
///   馬上再拿會被誤報正在處理中；明確解鎖不管有幾個複本都立刻生效（`flock(2)`：鎖屬於這一次開啟，複本共用同一把鎖）。
public final class SessionLock: Sendable {
    /// 鎖住的資料夾的描述子；釋放之後是 -1。
    private let descriptor: Mutex<Int32>

    /// 開資料夾的方式：唯讀、只能是資料夾，子程式 exec 時關掉（close-on-exec）。
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit {
        release()
    }

    /// 試著鎖住 `directory`，不等待。別人（包括同一個程式裡的其他地方）正持有時回傳 nil。
    /// 資料夾打不開（例如不存在）時丟出錯誤。
    public static func acquire(_ directory: SessionDirectory) throws -> SessionLock? {
        let descriptor = open(directory.url.path, Self.openFlags)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return SessionLock(descriptor: descriptor) }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// 有沒有人（包括同一個程式裡的其他地方）正持有 `directory` 的鎖。資料夾不存在時回答 false。
    public static func isHeld(_ directory: SessionDirectory) -> Bool {
        let descriptor = open(directory.url.path, Self.openFlags)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return errno == EWOULDBLOCK }
        // 拿得到就表示沒有人持有：馬上明確解鎖，不靠關閉（理由見上面的說明）
        flock(descriptor, LOCK_UN)
        return false
    }

    /// 釋放。可以重複呼叫；物件被釋放時也會自動釋放。
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            // 先明確解鎖再關閉：子程式手上可能剛好有描述子的複本，只靠關閉要等複本也關掉才會放開
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
