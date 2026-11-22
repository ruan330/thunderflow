/// 錄音中一直收不到聲音時，要不要提醒、提醒什麼（DESIGN.md 5.4 節）。純函式，有測試。
///
/// 系統音訊在沒有人播放時本來就是靜音：「按下開始，再去播放影片」是正常的用法，不提醒
/// （狀態列的音量表已經看得出是靜音）。只有別的程式真的在出聲、這裡卻一直收到靜音時，
/// 才可能是還沒有允許錄製系統音訊。
public enum SilenceWarning: Sendable, Equatable {
    /// 麥克風一直是靜音：可能選錯麥克風、被靜音，或沒有麥克風的權限（系統只給靜音，不回報錯誤）。
    case microphone
    /// 別的程式正在出聲，系統音訊卻一直是靜音：通常是還沒有允許錄製系統音訊。
    case systemAudio

    /// 來源的種類。
    public enum Source: Sendable {
        case microphone, systemAudio, file
    }

    /// 開始之後（不算暫停）至少一直是靜音這麼久才提醒。
    public static let minimumQuietSeconds = 6.0
    /// 系統音訊：別的程式至少持續出聲這麼久才算。一聲提示音、或剛按下播放時，聲音可能還沒傳到這裡。
    public static let minimumOthersPlayingSeconds = 1.0

    /// - Parameters:
    ///   - source: 來源的種類。
    ///   - quietSeconds: 開始之後（不算暫停）一直是靜音的長度。
    ///   - heardSound: 這一場有沒有收到過聲音。收到過就不提醒：權限沒有問題，之後的安靜是正常的。
    ///   - othersPlayingSeconds: 別的程式已經持續出聲多久（只看系統音訊；沒有程式在出聲、或不知道時是 0）。
    /// - Returns: 要提醒的內容；不需要提醒時是 nil。
    public static func check(
        source: Source, quietSeconds: Double, heardSound: Bool, othersPlayingSeconds: Double
    ) -> SilenceWarning? {
        guard !heardSound, quietSeconds >= minimumQuietSeconds else { return nil }
        switch source {
        case .file: return nil
        case .microphone: return .microphone
        case .systemAudio: return othersPlayingSeconds >= minimumOthersPlayingSeconds ? .systemAudio : nil
        }
    }

    /// 橫幅的說明：發生了什麼、錄音有沒有受影響、該怎麼處理。
    public var message: String {
        switch self {
        case .microphone:
            "開始 6 秒了，還沒有偵測到任何聲音。請確認選對了麥克風、沒有靜音，而且「系統設定 → 隱私權與安全性 → 麥克風」已經允許 ThunderFlow。"
        case .systemAudio:
            "別的 App 正在播放聲音，ThunderFlow 收到的卻一直是靜音，通常是還沒有允許錄製系統音訊。"
                + "請到「系統設定 → 隱私權與安全性」，在錄製系統音訊的項目裡允許 ThunderFlow，然後停止再重新開始。"
                + "如果那個 App 只是開著、沒有真的出聲，可以不用理會。"
        }
    }
}
