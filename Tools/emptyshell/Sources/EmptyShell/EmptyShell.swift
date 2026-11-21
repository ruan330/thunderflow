import AppKit
import Darwin
import SwiftUI

/// 和 ThunderFlow 一樣大小的視窗，裡面只有一行字。量測的寫法和 ThunderFlow 的 `LaunchProbe` 相同。
@main
struct EmptyShell: App {
    init() {
        if UserDefaults.standard.bool(forKey: "reportLaunch") {
            print(String(format: "launch.appInit.ms %.1f", Probe.millisecondsSinceProcessStart()))
        }
    }

    var body: some Scene {
        WindowGroup("EmptyShell") {
            Text("Empty")
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { Probe.firstAppearance() }
        }
        .defaultSize(width: 1_100, height: 720)
    }
}

@MainActor
enum Probe {
    private static var reported = false

    static func firstAppearance() {
        guard !reported, UserDefaults.standard.bool(forKey: "reportLaunch") else { return }
        reported = true
        DispatchQueue.main.async {
            print(String(format: "launch.firstFrame.ms %.1f", millisecondsSinceProcessStart()))
            fflush(stdout)
            if UserDefaults.standard.bool(forKey: "quitAfterLaunch") { NSApp.terminate(nil) }
        }
    }

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
