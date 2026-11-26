import SwiftUI

/// ThunderFlow 的 iPhone 版（DESIGN.md 5.10 節，D36）：只做錄音、即時翻譯與標記，其他都在 Mac 上。
@main
struct ThunderFlowPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LiveScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.phosphor)
                .task {
                    await model.refreshKeyState()
                    // 上次留在手機上的場次（沒選收件匣、App 被關掉）：收尾、交出去
                    await model.handoff.processPending()
                    model.showHandoffNotice()
                    await model.runSelfTestIfRequested()
                    await model.runLibrarySelfTestIfRequested()
                }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}

/// 外觀（DESIGN.md 4.10 節）：永遠是深色，錄音中與即時的東西用螢光綠。
enum Theme {
    static let phosphor = Color(red: 0xA6 / 255, green: 0xF2 / 255, blue: 0x4A / 255)
    static let background = Color(red: 0.06, green: 0.07, blue: 0.06)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.11)
    static let flag = Color(red: 0.98, green: 0.80, blue: 0.20)
}
