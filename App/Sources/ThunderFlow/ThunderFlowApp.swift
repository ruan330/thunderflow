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
        // 固定深色（DESIGN.md 4.10.1 節、D27）：不跟隨系統的外觀設定，也不提供外觀的選項。
        // 放在量測點之後：這一行會建立 NSApplication（約 50 ms），量測點量的是載入程式與框架的時間
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
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
            Hairline(axis: .vertical).ignoresSafeArea()
            Group {
                switch model.page {
                case .live: LiveView()
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 內容區是不透明的墨黑；側邊欄維持系統的側邊欄材質（DESIGN.md 4.10.3 節）
            .background(Theme.ink0)
            .overlay(alignment: .bottom) {
                ToastOverlay().padding(.bottom, 16)
            }
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
            SidebarItem(page: .live, title: "即時翻譯", icon: .bolt, key: "1")
            SidebarItem(
                page: .library, title: "過去錄音", icon: .system("list.bullet.rectangle"), key: "2",
                badge: model.processing.count)
            SidebarItem(page: .settings, title: "設定", icon: .system("gearshape"), key: "3")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 180)
        // 材質一路延伸到標題列底下，和內容區的墨黑一樣
        .background { SidebarMaterial().ignoresSafeArea() }
    }
}

/// 側邊欄的一項。和系統的側邊欄一樣，滑鼠按下就切換（DESIGN.md 4.10.5 節），不等放開。
private struct SidebarItem: View {
    enum Icon {
        /// App 圖示的閃電（即時翻譯）。
        case bolt
        case system(String)
    }

    @Environment(AppModel.self) private var model
    let page: AppModel.Page
    let title: String
    let icon: Icon
    let key: KeyEquivalent
    var badge = 0
    @State private var hovering = false

    var body: some View {
        let selected = model.page == page
        Button {
            select()
        } label: {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.bolt : Color.secondary)
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
            .background(
                Color.white.opacity(selected ? 0.10 : hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 按下的那一刻就切換；放開時 Button 的動作再切一次（已經是這一頁，不會有變化）
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in select() })
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .bolt: BoltShape().aspectRatio(BoltShape.aspectRatio, contentMode: .fit).frame(height: 14)
        case .system(let name): Image(systemName: name)
        }
    }

    private func select() {
        if model.page != page { model.page = page }
    }
}

/// 結果在畫面上看不到的操作（標記、複製、儲存 Key）做完之後的提示（DESIGN.md 4.10.5 節）：
/// 內容區底部置中，1.5 秒後消失；新的一則取代舊的。不接受點擊，不擋住底下的東西。
private struct ToastOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toast = model.toast
        ZStack {
            if let toast {
                ToastCapsule(toast: toast)
                    .id(toast.id)
                    .transition(Theme.transition(.offset(y: 6), reduceMotion: reduceMotion))
            }
        }
        .animation(Theme.standard, value: toast?.id)
        .allowsHitTesting(false)
        .onChange(of: toast?.id) {
            // VoiceOver 也念出來：提示不會拿到焦點
            if let toast = model.toast { AccessibilityNotification.Announcement(toast.text).post() }
        }
    }
}

private struct ToastCapsule: View {
    let toast: Toast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(toast.text)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.ink2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1 / max(displayScale, 1)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    @ViewBuilder private var icon: some View {
        switch toast.kind {
        case .marked: Image(systemName: "flag.fill").foregroundStyle(Theme.mark)
        case .copied, .saved: Image(systemName: "checkmark").foregroundStyle(Theme.bolt)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
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
///
/// `isOpen` 給即時翻譯頁的開關用；使用者按字幕視窗自己的關閉鈕時也會更新（`windowWillClose`）。
@MainActor
@Observable
final class FloatingCaptions: NSObject, NSWindowDelegate {
    static let shared = FloatingCaptions()
    /// 字幕視窗開著沒有。
    private(set) var isOpen = false
    @ObservationIgnored private var panel: NSPanel?

    func toggle(model: AppModel) {
        if let panel {
            // 關掉之後由 windowWillClose 更新狀態
            panel.close()
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
        panel.delegate = self
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
    }

    /// 字幕視窗關掉了：不論是開關關的，還是使用者按了字幕視窗自己的關閉鈕。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, window === panel else { return }
        window.delegate = nil
        panel = nil
        isOpen = false
    }
}

/// 浮動視窗的內容：最新的兩段中文與一段英文，和主視窗的字幕區一樣（同一句合成一段、句尾不顯示「。」）。
struct FloatingCaptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let board = model.captions.board
        let mode = model.settings.displayMode
        let showsProvisional = model.settings.showsProvisional
        // 只算最後幾段：一直拿著整份字幕的話，下一次更新時整份字幕都要複製一次（見 LiveCaptionModel.flush）
        let chinese = CaptionZoneSync.lastParagraphs(
            board: board, marked: [],
            options: CaptionZoneOptions(language: .chinese, showsProvisional: showsProvisional, showsFlags: false, hidesFinalPeriod: true),
            count: 2)
        let english = CaptionZoneSync.lastParagraphs(
            board: board, marked: [],
            options: CaptionZoneOptions(language: .english, showsProvisional: showsProvisional, showsFlags: false), count: 1
        ).first
        VStack(alignment: .leading, spacing: 6) {
            if mode != .english {
                ForEach(Array(chinese.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph.text).foregroundStyle(paragraph.kind == .settled ? .primary : .secondary)
                }
            }
            if mode != .chinese, let english {
                Text(english.text)
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
///     ThunderFlow -selfTestFile <音檔> [-selfTestSeconds 30] [-selfTestSnapshot <路徑前綴>] [-selfTestMark YES]
///                 [-selfTestQuit YES] [-libraryPath <資料夾>] [-workingPath <資料夾>] [-apiKeyFromStdin YES]
///
/// 截圖依序是開始前（`-idle.png`）、錄音中（`-live.png`）、結束後的詳細頁（`-detail.png`）、設定頁（`-settings.png`），
/// 以及從設定頁切回過去錄音、還沒選任何一場時的清單（`-library.png`，同時印出清單有幾列、看得到幾列）。
/// `-selfTestMark YES` 在錄音中的截圖前 1 秒標記一次重點，截圖裡就看得到提示與字幕的旗子。用法見 CLAUDE.md。
@MainActor
enum SelfTest {
    static func runIfRequested(_ model: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "diagnoseCapture") {
            diagnoseCapture()
            return
        }
        if let prefix = defaults.string(forKey: "selfTestCaptions") {
            previewCaptions(model, to: prefix)
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
        let marks = defaults.bool(forKey: "selfTestMark")
        Task {
            model.source = device ?? .file(URL(fileURLWithPath: defaults.string(forKey: "selfTestFile") ?? ""))
            model.title = defaults.string(forKey: "selfTestTitle") ?? ""
            if let prefix { snapshot(to: prefix + "-idle.png") }
            await model.start()
            print("selfTest: started state=\(model.liveState) banner=\(model.banner ?? "-") \(model.captureDiagnostics)")
            let limit = seconds > 0 ? seconds : 3_600
            let started = ContinuousClock.now
            var lastReport = ContinuousClock.now
            var marked = !marks
            while model.isRecording, ContinuousClock.now - started < .seconds(limit) {
                try? await Task.sleep(for: .milliseconds(200))
                if !marked, ContinuousClock.now - started >= .seconds(max(0, limit - 1)) {
                    marked = true
                    model.mark()
                }
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
                // 從別頁切到過去錄音、還沒選任何一場時的清單（`-library.png`），和使用者從側邊欄點進來一樣。
                // 同時印出清單有幾列、看得到幾列：只顯示一部分時，分得出是資料少了還是沒畫出來。
                model.selectedSession = nil
                model.page = .library
                for wait in [100, 400, 1_000] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    print("selfTest: library sessions=\(model.sessions.count) \(listDiagnostics())")
                }
                snapshot(to: prefix + "-library.png")
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

    /// 字幕區的外觀檢查（不錄音、不連線、不需要 Key）：`-selfTestCaptions <路徑前綴>` 把一組固定的字幕放進字幕區，
    /// 畫成 `<前綴>.png`。內容涵蓋每一種樣子：定稿（會換行的長句）、標記的旗子、未翻譯、暫定譯文、「…」、
    /// 正在說的那一段（英文與它的暫定譯文）。顯示模式用啟動參數 `-displayMode chinese|english|bilingual` 指定：
    /// 啟動參數只影響這一次執行，不會改到使用者的設定。改動字幕區的外觀之後，用它比對改之前與改之後的圖。
    static func previewCaptions(_ model: AppModel, to prefix: String) {
        // 整句模式（DESIGN.md 5.6.2 節）：英文帶句子的編號，整句定稿涵蓋這一句的段
        func source(_ text: String, _ segment: Int, sentence: Int, ended: Bool = true) -> CaptionEvent {
            .source(CaptionText(text: text, kind: ended ? .segmentEnd : .delta, at: .zero, segment: segment, sentence: sentence))
        }
        func final(_ text: String, _ segment: Int) -> CaptionEvent {
            .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
        }
        func sentenceFinal(_ text: String, sentence: Int, first: Int, last: Int) -> CaptionEvent {
            .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: last, sentence: sentence, sentenceStart: first))
        }
        let events: [CaptionEvent] = [
            source("Today I want to talk about", 0, sentence: 0),
            final("今天我想談談", 0),
            source("how we are making it easier to build production-ready agents.", 1, sentence: 0),
            sentenceFinal("今天我想談談，我們如何讓打造可上線的代理程式變得更容易。", sentence: 0, first: 0, last: 1),
            source("Amazon Bedrock AgentCore gives you three core components: a runtime, a gateway, and memory.", 2, sentence: 1),
            sentenceFinal("Amazon Bedrock AgentCore 提供三個核心元件：執行環境、閘道與記憶。", sentence: 1, first: 2, last: 2),
            source("Let me show you a quick demo.", 3, sentence: 2),
            // 第 2 句沒有任何定稿：下一句的整句定稿到了，它就是沒翻到
            source("Each agent runs in its own isolated session,", 4, sentence: 3),
            final("每個代理程式都在自己獨立的工作階段裡執行，", 4),
            source("so one customer's data never leaks into another's.", 5, sentence: 3),
            sentenceFinal("每個代理程式都在自己獨立的工作階段裡執行，所以一位客戶的資料絕對不會流到另一位客戶那裡。", sentence: 3, first: 4, last: 5),
            // 正在說的這一句：前一段的定稿先出（灰字），正在說的英文接在後面
            source("And you only pay for", 6, sentence: 4),
            final("而且你只需要支付", 6),
            source(" the compute you actually use", 7, sentence: 4, ended: false),
        ]
        Task {
            for event in events { model.captions.receive(event) }
            model.captions.flush()
            model.previewMarks([2, 5])
            try? await Task.sleep(for: .milliseconds(800))
            snapshot(to: prefix + ".png")
            print("selfTest: captions done")
            fflush(stdout)
            if UserDefaults.standard.bool(forKey: "selfTestQuit") { NSApp.terminate(nil) }
        }
    }

    /// 把主視窗的內容畫成圖檔（在程式裡自己畫，不需要螢幕錄製的權限）。
    /// 畫面上每個清單（NSTableView）的列數、看得到的列數與可見的高度。
    static func listDiagnostics() -> String {
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            view.subviews.forEach(walk)
        }
        for window in NSApp.windows {
            if let content = window.contentView { walk(content) }
        }
        return tables.map { table in
            "rows=\(table.numberOfRows) visible=\(table.rows(in: table.visibleRect).length) height=\(Int(table.visibleRect.height))"
        }.joined(separator: "; ")
    }

    static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil })?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
