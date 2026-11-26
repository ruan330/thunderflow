/// 即時翻譯頁的來源選單（DESIGN.md 4.3 節，D35）。還沒實作：照舊只有還沒開始時能用。
public enum SourceMenu {
    public static func isEnabled(phase: RecorderPhase, switching: Bool, recordingFromFile: Bool) -> Bool {
        phase == .idle
    }

    public static func offersFile(phase: RecorderPhase) -> Bool {
        true
    }
}
