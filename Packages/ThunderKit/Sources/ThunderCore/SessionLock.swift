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
/// - 系統支援時（`isForkSafe`），描述子設 close-on-fork（`O_CLOFORK`）：別的執行緒啟動子程式（例如 workshop-archive）時，
///   子程式不會拿到它的複本。只設 close-on-exec 的話，子程式要等到 exec 才關掉複本，這段時間裡放掉的鎖還被占著，
///   馬上再拿會被誤報正在處理中。不支援的系統照舊（只設 close-on-exec）。
public final class SessionLock: Sendable {
    /// 鎖住的資料夾的描述子；釋放之後是 -1。
    private let descriptor: Mutex<Int32>

    /// close-on-fork 的兩個數值（`sys/fcntl.h` 的 `O_CLOFORK`、`FD_CLOFORK`）。macOS 27、iOS 27 的 SDK 才有這兩個名稱，
    /// 舊的 SDK（例如 CI 用的 macOS 26）編不過，所以直接寫數值。
    private static let openCloseOnFork: Int32 = 0x0800_0000
    private static let descriptorCloseOnFork: Int32 = 2

    /// 這個系統支不支援 close-on-fork：開一次暫存資料夾，看描述子有沒有真的設上（不支援的系統可能直接忽略這個旗標）。
    /// 不支援時鎖照樣能用，只是別的執行緒啟動子程式的那一瞬間，剛放掉的鎖可能被多占一下（誤報正在處理中，實測約 1%）。
    public static let isForkSafe: Bool = {
        let descriptor = open(NSTemporaryDirectory(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | openCloseOnFork)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fcntl(descriptor, F_GETFD) & descriptorCloseOnFork != 0
    }()

    /// 開資料夾的方式：唯讀、只能是資料夾，子程式不繼承（close-on-exec；系統支援時再加 close-on-fork）。
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (isForkSafe ? openCloseOnFork : 0)

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
        // 拿得到就表示沒有人持有；關閉描述子時這一次拿到的鎖也跟著釋放
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    /// 釋放。可以重複呼叫；物件被釋放時也會自動釋放。
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            // 關閉描述子就釋放了鎖
            close(descriptor)
            descriptor = -1
        }
    }
}
