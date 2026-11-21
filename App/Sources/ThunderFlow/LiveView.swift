import AppKit
import SwiftUI
import ThunderAudio
import ThunderCore
import ThunderUI
import UniformTypeIdentifiers

/// 即時翻譯頁（DESIGN.md 4.3 節）：上面是場次資訊與開始／停止，中間是狀態，下面是中文與英文兩區字幕。
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            header
            Divider()
            statusRow
            Divider()
            CaptionsView()
        }
        .navigationTitle("即時翻譯")
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            TextField("標題（選填）", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .disabled(model.isRecording)
            Button {
                showsDetails.toggle()
            } label: {
                Label("場次資訊與關鍵詞", systemImage: "text.badge.plus")
            }
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) { SessionDetailsForm() }
            Spacer()
            SourcePicker()
                .disabled(model.liveState != .idle)
            startButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var startButton: some View {
        switch model.liveState {
        case .idle:
            Button {
                Task { await model.start() }
            } label: {
                Label("開始錄音", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
        case .starting:
            Button("準備中…") {}.disabled(true)
        case .recording, .paused:
            Button {
                model.togglePause()
            } label: {
                Label(model.liveState == .paused ? "繼續" : "暫停", systemImage: model.liveState == .paused ? "play.fill" : "pause.fill")
            }
            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(".", modifiers: .command)
        case .stopping:
            Button("收尾中…") {}.disabled(true)
        }
    }

    private var statusRow: some View {
        @Bindable var settings = model.settings
        return HStack(spacing: 14) {
            StatusChip(text: recordingLabel, color: recordingColor)
            if model.isRecording {
                StatusChip(text: engineLabel, color: engineColor)
                Text(Format.duration(model.elapsed)).monospacedDigit()
                LevelMeter(level: model.level)
                Text(Format.cost(audioSeconds: model.elapsed, provisional: model.settings.showsProvisional))
                    .foregroundStyle(.secondary)
                if !model.sourceDescription.isEmpty {
                    Text(model.sourceDescription).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.isRecording {
                Button {
                    model.mark()
                } label: {
                    Label("標記重點", systemImage: "flag")
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            Button {
                FloatingCaptions.shared.toggle(model: model)
            } label: {
                Label("浮動字幕", systemImage: "rectangle.on.rectangle")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Picker("顯示", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Stepper("字級 \(Int(settings.fontSize))", value: $settings.fontSize, in: 14...48, step: 2)
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var recordingLabel: String {
        switch model.liveState {
        case .idle: "尚未開始"
        case .starting: "準備中"
        case .recording: "錄音中"
        case .paused: "已暫停"
        case .stopping: "收尾中"
        }
    }

    private var recordingColor: Color {
        switch model.liveState {
        case .recording: .red
        case .paused: .orange
        default: .secondary
        }
    }

    /// 翻譯的狀態和錄音分開顯示：翻譯斷線時，錄音仍然持續。
    private var engineLabel: String {
        switch model.captions.engineStatus {
        case .none, .connecting?: "翻譯連線中"
        case .live?: "翻譯即時"
        case .reconnecting?: "翻譯重新連線中，錄音持續中"
        case .idle?: "翻譯待命"
        case .failed(let reason)?: "翻譯已停止：\(reason)（錄音持續中）"
        }
    }

    private var engineColor: Color {
        switch model.captions.engineStatus {
        case .live?: .green
        case .failed?: .red
        default: .orange
        }
    }
}

/// 中文（大字）與英文（小字、灰色）兩區字幕，各自自動捲到最新；往上捲時暫停自動捲動。
struct CaptionsView: View {
    @Environment(AppModel.self) private var model

    /// 畫面上最多畫幾行（約半小時）。只畫最後這幾行，畫面的成本才不會隨場次變長。
    /// 而且畫面不能一直拿著整份字幕：拿著的話，下一次更新時整份字幕都要複製一次（見 `LiveCaptionModel.flush`），
    /// 所以這裡只把最後幾行複製出來，下面的內容也不引用整份字幕。更早的內容在結束後的逐字稿裡。
    static let visibleLines = 400

    var body: some View {
        let board = model.captions.board
        let lines = Array(board.lines.suffix(Self.visibleLines))
        let earlier = board.lines.count - lines.count
        let liveEnglish = board.liveEnglish
        let liveChinese = board.liveChinese
        let mode = model.settings.displayMode
        let size = model.settings.fontSize
        let showsProvisional = model.settings.showsProvisional
        if lines.isEmpty, liveEnglish.isEmpty {
            ContentUnavailableView(
                "按下「開始錄音」", systemImage: "waveform",
                description: Text("講者說英文時，這裡會即時出現英文逐字稿與台灣繁體中文翻譯。"))
        } else {
            VSplitView {
                if mode != .english {
                    CaptionZone(title: "中文", updates: model.captions.updateCount) {
                        if earlier > 0 { EarlierNote(count: earlier) }
                        ForEach(lines) { line in
                            ChineseLine(line: line, showsProvisional: showsProvisional).font(.system(size: size))
                        }
                        if showsProvisional, !liveChinese.isEmpty {
                            Text(liveChinese).font(.system(size: size)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 120)
                }
                if mode != .chinese {
                    CaptionZone(title: "English", updates: model.captions.updateCount) {
                        if earlier > 0 { EarlierNote(count: earlier) }
                        ForEach(lines) { line in
                            Text(line.english).font(.system(size: mode == .english ? size : size * 0.72)).foregroundStyle(.secondary)
                        }
                        if !liveEnglish.isEmpty {
                            Text(liveEnglish.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: mode == .english ? size : size * 0.72))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 90)
                }
            }
        }
    }
}

/// 畫面上沒有畫出來的較早內容。
private struct EarlierNote: View {
    let count: Int

    var body: some View {
        Text("較早的 \(count) 段在結束後的逐字稿裡").font(.caption).foregroundStyle(.secondary)
    }
}

/// 一行中文：有定稿用定稿；沒有的話，允許時顯示暫定譯文（淡色）；確定不會有定稿時先顯示英文並標示「未翻譯」。
private struct ChineseLine: View {
    let line: CaptionBoard.Line
    let showsProvisional: Bool

    var body: some View {
        let text = line.chinese.isEmpty ? (showsProvisional ? line.provisional : "") : line.chinese
        if !line.chinese.isEmpty {
            Text(text)
        } else if line.untranslated {
            // 這一段沒翻到：先顯示英文，結束後補上
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.english).foregroundStyle(.secondary)
                Text("未翻譯").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
        } else if !text.isEmpty {
            Text(text).foregroundStyle(.tertiary)
        } else {
            Text("…").foregroundStyle(.tertiary)
        }
    }
}

/// 一區字幕：新的內容出現時捲到最下面；使用者往上捲之後就不再自動捲，並出現「回到最新」。
struct CaptionZone<Content: View>: View {
    let title: String
    let updates: Int
    @ViewBuilder var content: Content
    @State private var pinned = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    content
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, atBottom in
                pinned = atBottom
            }
            .onChange(of: updates) {
                if pinned { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button {
                        pinned = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                    }
                    .padding(12)
                }
            }
        }
    }
}

struct SessionDetailsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            TextField("活動", text: $model.event, prompt: Text("例如 AWS re:Invent 2026"))
            TextField("講者", text: $model.speaker)
            Section("這一場的關鍵詞（一行一個：人名、產品名稱、術語）") {
                TextEditor(text: $model.sessionKeywords).font(.body.monospaced()).frame(height: 120)
            }
            Text("場次資訊與關鍵詞會提供給轉錄模型與翻譯模型，讓專有名詞寫對。不填也沒關係。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .disabled(model.isRecording)
    }
}

struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("來源", selection: $model.source) {
            Text("系統音訊").tag(AppModel.SourceChoice.system)
            Text("麥克風（系統預設）").tag(AppModel.SourceChoice.microphone(uid: ""))
            ForEach(model.devices) { device in
                Text(device.name).tag(AppModel.SourceChoice.microphone(uid: device.uid))
            }
            if case .file(let url) = model.source {
                Text("音檔：\(url.lastPathComponent)").tag(AppModel.SourceChoice.file(url))
            }
        }
        .frame(maxWidth: 260)
        .onChange(of: model.source) { _, new in
            switch new {
            case .system: model.settings.sourceKey = "system"
            case .microphone(let uid): model.settings.sourceKey = uid
            case .file: break
            }
        }
        .contextMenu {
            Button("重新整理裝置清單") { model.refreshDevices() }
            Button("用音檔當來源…（測試用）") { chooseFile() }
        }
        Button {
            chooseFile()
        } label: {
            Image(systemName: "doc.badge.plus")
        }
        .help("用音檔當來源（測試用）：以即時速度播放，不需要麥克風")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.source = .file(url) }
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        // 音量以分貝顯示才看得出變化：-50 dB 到 0 dB
        let decibels = 20 * log10(max(Double(level), 0.000_01))
        let fraction = min(1, max(0, (decibels + 50) / 50))
        Capsule().fill(.quaternary).frame(width: 60, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(fraction > 0.95 ? Color.red : Color.green).frame(width: 60 * fraction, height: 6)
            }
            .accessibilityLabel("音量")
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            Button("關閉", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}
