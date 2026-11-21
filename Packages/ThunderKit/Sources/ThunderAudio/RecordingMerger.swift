import AVFoundation
import Foundation

public enum RecordingMergerError: Error, Equatable {
    /// 沒有任何聲音可以合併：沒有分段，或分段都是空的。
    case noAudio
    /// 取樣率轉換失敗。
    case conversionFailed
}

/// 合併錄音（結束處理的第 4 步）：把 CAF 分段依序接起來，編碼成一個 m4a（AAC、單聲道、64 kbps）。
///
/// - 一批一批地讀、轉、寫，不會把整場錄音載入記憶體。
/// - 取樣率用第一個分段的；其他取樣率的分段會先轉成它。AAC 不支援的取樣率（例如 96 kHz）
///   改用不超過它的最高支援取樣率（48 kHz）。
/// - 位元率是 64 kbps；取樣率太低、編碼器不接受 64 kbps 時（16 kHz 以下），用它接受的最高位元率。
/// - 先寫進目的地所在資料夾裡的暫存檔（`.<檔名>.<UUID>.tmp.m4a`），寫完、fsync 之後才改名成目的地，
///   所以目的地不會出現寫到一半的檔案；失敗時刪掉暫存檔。開始前會清掉上次中斷留下的暫存檔。
/// - 不會改動來源的分段檔。要不要刪除它們由呼叫端決定：先確認回傳的時長和分段的總長一致。
public enum RecordingMerger {
    /// 合併 `segments`（依陣列的順序），寫到 `url`，回傳成品實際的時長（秒，從寫好的檔案讀出來）。
    ///
    /// 沒有任何聲音可以合併時丟出 `RecordingMergerError.noAudio`，不建立檔案。
    /// 某個分段檔比它的檔頭宣稱的短（被截斷）時，合併讀得到的部分；回傳的時長因此會比分段的總長短，
    /// 呼叫端據此知道成品不完整。
    public static func merge(segments: [RecordingSegment], to url: URL) throws -> TimeInterval {
        // 尚未實作（M3）
        0
    }

    /// 音訊檔的時長（秒）。
    public static func duration(of url: URL) throws -> TimeInterval {
        // 尚未實作（M3）
        0
    }
}
