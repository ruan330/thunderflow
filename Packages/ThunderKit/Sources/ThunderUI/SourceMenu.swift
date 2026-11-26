/// 即時翻譯頁的來源選單（DESIGN.md 4.3 節，D35）：錄音中、暫停中都能換來源，接著錄同一場。
public enum SourceMenu {
    /// 選單能不能用：還沒開始、錄音中、暫停中都可以。開始中、收尾中不行（收音正在開始或結束），
    /// 正在換的那一下也不行（等這一次換好）。用音檔（測試用）錄音時不能換：音檔播完會自動停止，換掉之後這個規則就不成立。
    public static func isEnabled(phase: RecorderPhase, switching: Bool, recordingFromFile: Bool) -> Bool {
        switch phase {
        case .idle: true
        case .recording, .paused: !switching && !recordingFromFile
        case .starting, .stopping: false
        }
    }

    /// 能不能選音檔當來源：只有還沒開始時。
    public static func offersFile(phase: RecorderPhase) -> Bool {
        phase == .idle
    }
}
