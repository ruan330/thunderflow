import AppKit
import SwiftUI
import ThunderCore
import ThunderUI

@main
struct ThunderFlowApp: App {
    @State private var model = AppModel()

    init() {
        // `ThunderFlow --version`：印出版本就結束。打包腳本用它確認簽章之後的程式能執行。
        if CommandLine.arguments.contains("--version") {
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            exit(0)
        }
        LaunchProbe.appInit()
        // 只有一個主視窗：沒有分頁（分頁的「＋」會開出第二個視窗）
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("ThunderFlow") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            // ⌘N 是「開始錄音」（DESIGN.md 4.8 節），不是開新視窗。只有一個主視窗
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// 左側固定三項：即時翻譯、過去錄音、設定（DESIGN.md 4.1 節）。
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.page) {
                Label("即時翻譯", systemImage: "waveform").tag(AppModel.Page.live)
                Label("過去錄音", systemImage: "list.bullet.rectangle").tag(AppModel.Page.library)
                    .badge(model.processing.count)
                Label("設定", systemImage: "gearshape").tag(AppModel.Page.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch model.page {
            case .live: LiveView()
            case .library: LibraryView()
            case .settings: SettingsView()
            }
        }
        .onAppear { LaunchProbe.firstAppearance() }
        // 畫面先出現，資料隨後補上
        .task { await model.didAppear() }
    }
}

/// 浮動字幕視窗（DESIGN.md 4.4 節）：永遠在最上層，可以跨桌面、疊在全螢幕 App 上。
@MainActor
final class FloatingCaptions {
    static let shared = FloatingCaptions()
    private var panel: NSPanel?

    func toggle(model: AppModel) {
        if let panel {
            panel.close()
            self.panel = nil
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 170),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        panel.title = "ThunderFlow 字幕"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingCaptionsView().environment(model))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 450, y: frame.minY + 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// 浮動視窗的內容：最新的兩段中文（加上正在說的那一段的暫定譯文）與一行英文。
struct FloatingCaptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let board = model.captions.board
        // 只複製最後兩行出來（不引用整份字幕，見 CaptionsView.visibleLines 的說明）
        let recent = Array(board.lines.suffix(2))
        let mode = model.settings.displayMode
        let showsProvisional = model.settings.showsProvisional
        VStack(alignment: .leading, spacing: 6) {
            if mode != .english {
                ForEach(recent) { line in
                    let text = line.chinese.isEmpty ? (showsProvisional ? line.provisional : "") : line.chinese
                    Text(text.isEmpty ? line.english : text)
                        .foregroundStyle(line.chinese.isEmpty ? .secondary : .primary)
                }
                if showsProvisional, !board.liveChinese.isEmpty {
                    Text(board.liveChinese).foregroundStyle(.secondary)
                }
            }
            if mode != .chinese {
                let english = board.liveEnglish.isEmpty ? (board.lines.last?.english ?? "") : board.liveEnglish
                Text(english.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if board.lines.isEmpty, board.liveEnglish.isEmpty {
                Text("開始錄音後，字幕會顯示在這裡。").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 26, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(16)
    }
}

/// 自我檢查：用音檔當來源跑完一整場，並把畫面存成圖檔。只在啟動參數要求時執行，給開發時驗證用。
///
///     ThunderFlow -selfTestFile <音檔> [-selfTestSeconds 30] [-selfTestSnapshot <路徑前綴>]
///                 [-selfTestQuit YES] [-libraryPath <資料夾>] [-workingPath <資料夾>] [-apiKeyFromStdin YES]
///
/// 用法見 CLAUDE.md。
@MainActor
enum SelfTest {
    static func runIfRequested(_ model: AppModel) {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "selfTestFile") else { return }
        let seconds = defaults.double(forKey: "selfTestSeconds")
        let prefix = defaults.string(forKey: "selfTestSnapshot")
        Task {
            model.source = .file(URL(fileURLWithPath: path))
            model.title = defaults.string(forKey: "selfTestTitle") ?? ""
            await model.start()
            let limit = seconds > 0 ? seconds : 3_600
            let started = ContinuousClock.now
            while model.isRecording, ContinuousClock.now - started < .seconds(limit) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if let prefix { snapshot(to: prefix + "-live.png") }
            await model.stop()
            // 停止可能是別的地方先觸發的（音檔播完、使用者按了停止）：等它做完
            while model.liveState != .idle { try? await Task.sleep(for: .milliseconds(100)) }
            // 等結束處理做完
            try? await Task.sleep(for: .milliseconds(500))
            while !model.processing.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(1_000))
            if let prefix {
                snapshot(to: prefix + "-detail.png")
                model.page = .settings
                try? await Task.sleep(for: .milliseconds(500))
                snapshot(to: prefix + "-settings.png")
            }
            let states = model.sessions.map { "\($0.meta.title.isEmpty ? "未命名" : $0.meta.title)｜\($0.meta.state.rawValue)｜\(Int($0.meta.durationSeconds)) 秒｜失敗的步驟 \($0.meta.failedSteps)" }
            print("selfTest: done banner=\(model.banner ?? "-") sessions=\(states)")
            if defaults.bool(forKey: "selfTestQuit") { NSApp.terminate(nil) }
        }
    }

    /// 把主視窗的內容畫成圖檔（在程式裡自己畫，不需要螢幕錄製的權限）。
    static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil })?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
