import AppKit
import SwiftUI
import ThunderAudio
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

/// 左側固定三項：即時翻譯、過去錄音、設定（DESIGN.md 4.1 節）。⌘1、⌘2、⌘3 切換。
///
/// 側邊欄自己畫，不用 NavigationSplitView：實測它讓第一個畫面慢約 90 ms，
/// 是啟動時間超過預算的主要原因（DESIGN.md 9.8 節，`Scripts/measure-app.sh`）。
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider()
            Group {
                switch model.page {
                case .live: LiveView()
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { LaunchProbe.firstAppearance() }
        // 畫面先出現，資料隨後補上
        .task { await model.didAppear() }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item(.live, "即時翻譯", systemImage: "waveform", key: "1")
            item(.library, "過去錄音", systemImage: "list.bullet.rectangle", key: "2", badge: model.processing.count)
            item(.settings, "設定", systemImage: "gearshape", key: "3")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 180)
        .background(SidebarMaterial())
    }

    private func item(
        _ page: AppModel.Page, _ title: String, systemImage: String, key: KeyEquivalent, badge: Int = 0
    ) -> some View {
        let selected = model.page == page
        return Button {
            model.page = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 系統側邊欄的半透明材質。
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
        if defaults.bool(forKey: "diagnoseCapture") {
            diagnoseCapture()
            return
        }
        // 來源：`-selfTestSource system`（系統音訊）、`-selfTestSource microphone`（預設的麥克風），或 `-selfTestFile <音檔>`
        let device: AppModel.SourceChoice? =
            switch defaults.string(forKey: "selfTestSource") {
            case "system": .system
            case "microphone": .microphone(uid: "")
            default: nil
            }
        guard device != nil || defaults.string(forKey: "selfTestFile") != nil else { return }
        let seconds = defaults.double(forKey: "selfTestSeconds")
        let prefix = defaults.string(forKey: "selfTestSnapshot")
        Task {
            model.source = device ?? .file(URL(fileURLWithPath: defaults.string(forKey: "selfTestFile") ?? ""))
            model.title = defaults.string(forKey: "selfTestTitle") ?? ""
            await model.start()
            print("selfTest: started state=\(model.liveState) banner=\(model.banner ?? "-") \(model.captureDiagnostics)")
            let limit = seconds > 0 ? seconds : 3_600
            let started = ContinuousClock.now
            var lastReport = ContinuousClock.now
            while model.isRecording, ContinuousClock.now - started < .seconds(limit) {
                try? await Task.sleep(for: .milliseconds(200))
                if ContinuousClock.now - lastReport >= .milliseconds(1_000) {
                    lastReport = ContinuousClock.now
                    print("selfTest: \(model.captureDiagnostics)")
                    fflush(stdout)
                }
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

    /// 實機檢查系統音訊的擷取（不連線、不需要 Key、不建立場次）：啟動參數 `-diagnoseCapture YES`，
    /// 秒數用 `-diagnoseSeconds`（預設 5）。和錄音時一樣在背景啟動擷取，每秒印出收到的樣本數與峰值，
    /// 最後印出收到的音訊長度與實際經過時間的比例：沒有任何 App 出聲時也應該接近 1（收到的是靜音）。
    static func diagnoseCapture() {
        Task {
            let defaults = UserDefaults.standard
            let seconds = defaults.integer(forKey: "diagnoseSeconds") > 0 ? defaults.integer(forKey: "diagnoseSeconds") : 5
            let ring = RingBuffer(minimumCapacity: 1 << 22)
            let capture = AudioCapture(source: .systemAudio, ring: ring)
            let began = ContinuousClock.now
            // 還沒有授權時，第一次開始收音會立刻失敗、同時跳出授權視窗；之後的嘗試會等到使用者回答才回來
            // （實機觀察）。其他原因的失敗每秒重試，最多 60 次
            var sampleRate = 0.0
            for attempt in 1...60 {
                do {
                    sampleRate = try await Task.detached { try capture.start() }.value
                    break
                } catch {
                    if attempt == 1 { print("diagnose: start failed, retrying every second for 60 s: \(error)") }
                    if attempt == 60 {
                        print("diagnose: gave up")
                        if defaults.bool(forKey: "selfTestQuit") { NSApp.terminate(nil) }
                        return
                    }
                    fflush(stdout)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            let started = ContinuousClock.now
            print("diagnose: started in \(started - began), sampleRate=\(sampleRate)")
            var buffer = [Float](repeating: 0, count: 1 << 20)
            var frames = 0
            for second in 1...seconds {
                try? await Task.sleep(until: started + .seconds(second), clock: .continuous)
                let count = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0) }
                frames += count
                let peak = buffer.prefix(count).reduce(Float(0)) { max($0, abs($1)) }
                print("diagnose: t=\(second)s callbacks=\(capture.mixer.callbackCount) frames=\(frames) peak=\(peak)")
                fflush(stdout)
            }
            let elapsed = (ContinuousClock.now - started).components
            let wall = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            capture.stop()
            let audio = sampleRate > 0 ? Double(frames) / sampleRate : 0
            print(
                String(
                    format: "diagnose: wall=%.2fs audio=%.2fs ratio=%.3f discontinuities=%d", wall, audio, audio / wall,
                    capture.mixer.discontinuityCount))
            fflush(stdout)
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
