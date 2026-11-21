import AppKit
import Darwin

/// 量測用（DESIGN.md 9.8 節）：啟動參數 `-reportLaunch YES` 時，第一個畫面出來之後在標準輸出印出
/// 「程序啟動到現在」的毫秒數；再加上 `-quitAfterLaunch YES` 就接著結束。`Scripts/measure-app.sh` 用它，
/// 空白的對照 App（`Tools/emptyshell`）也用同樣的寫法量。
@MainActor
enum LaunchProbe {
    private static var reported = false

    /// App 的 `init` 呼叫：從程序啟動到這裡，主要是載入程式與系統框架的時間。
    static func appInit() {
        guard UserDefaults.standard.bool(forKey: "reportLaunch") else { return }
        print(String(format: "launch.appInit.ms %.1f", millisecondsSinceProcessStart()))
    }

    /// 主視窗的內容出現時呼叫。只在要求量測時做事，而且只做一次。
    static func firstAppearance() {
        guard !reported, UserDefaults.standard.bool(forKey: "reportLaunch") else { return }
        reported = true
        // 等這一輪的版面配置與繪製做完再算
        DispatchQueue.main.async {
            print(String(format: "launch.firstFrame.ms %.1f", millisecondsSinceProcessStart()))
            fflush(stdout)
            if UserDefaults.standard.bool(forKey: "quitAfterLaunch") { NSApp.terminate(nil) }
        }
    }

    /// 從核心記錄的程序啟動時間（`p_starttime`）到現在的毫秒數。查不到時回傳 -1。
    nonisolated static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startedAt) * 1_000
    }
}
