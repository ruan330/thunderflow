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
                Hairline()
            }
            header
            Hairline()
            StatusStrip()
            Hairline()
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
            TransportControls()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // 停止鈕出現或收起時，左邊的東西跟著平順地移動（版面變化 280 ms）
        .animation(Theme.layout, value: TransportSlots(phase: model.shownPhase, preparingVisible: model.waitVisible).showsStop)
    }
}

// MARK: - 開始／停止

/// 開始／停止（DESIGN.md 4.10.5 節、D30）。
///
/// 主要位置固定在最右邊、寬度不變：「開始錄音」在錄音中變成「暫停」（暫停時是「繼續」）。「停止」只出現在它左邊，
/// 不會出現在主要位置，所以剛按下開始時手快多點一下，最多是暫停。狀態剛換的 0.5 秒內不接受點擊（`PressGuard`）；
/// 開始或停止在 0.3 秒內完成時不顯示「準備中」「收尾中」：按下的按鈕維持按下的樣子，直接換成結果
/// （`RecorderPhase.shown`；計時在 `AppModel`，狀態列與字幕區共用同一個）。位置的判斷都在 `TransportSlots`。
private struct TransportControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressGuard = PressGuard()

    var body: some View {
        let phase = model.recorderPhase
        // 按鈕照畫面上表示的階段排：等待未滿 0.3 秒時是等待之前的階段
        let slots = TransportSlots(phase: model.shownPhase, preparingVisible: model.waitVisible)
        HStack(spacing: 8) {
            if slots.showsStop {
                stopButton
                    .transition(Theme.transition(.move(edge: .trailing), reduceMotion: reduceMotion))
            }
            // 疊在一起換內容：換的時候新舊內容在同一個位置淡入淡出，不會並排撐開
            ZStack {
                mainSlot(slots.main, phase: phase)
            }
            .animation(Theme.standard, value: slots.main)
        }
        // 狀態一換，防連點的 0.5 秒就從現在重新起算
        .onChange(of: phase) { _, _ in pressGuard.stateChanged(at: .now) }
    }

    @ViewBuilder private func mainSlot(_ main: TransportSlots.Main, phase: RecorderPhase) -> some View {
        switch main {
        case .start:
            Button {
                perform { Task.immediate { await model.start() } }
            } label: {
                SlotLabel { Label("開始錄音", systemImage: "record.circle") }
            }
            .buttonStyle(PrimaryButtonStyle(isHeld: phase == .starting))
            .keyboardShortcut("n", modifiers: .command)
            // 開始中、「準備中」還沒出現：畫成按下去的樣子，不接受點擊
            .allowsHitTesting(phase == .idle)
        case .preparing:
            Button {} label: {
                SlotLabel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("準備中")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(isHeld: true))
            .disabled(true)
        case .pause:
            Button {
                perform { model.togglePause() }
            } label: {
                SlotLabel { Label("暫停", systemImage: "pause.fill") }
            }
            .buttonStyle(NeutralButtonStyle())
            // 按下停止、「收尾中」還沒出現：維持原樣，不接受點擊
            .allowsHitTesting(phase == .recording)
        case .resume:
            Button {
                perform { model.togglePause() }
            } label: {
                SlotLabel { Label("繼續", systemImage: "play.fill") }
            }
            .buttonStyle(NeutralButtonStyle())
            .allowsHitTesting(phase == .paused)
        case .finishing:
            Button {} label: {
                SlotLabel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("收尾中")
                    }
                }
            }
            .buttonStyle(NeutralButtonStyle())
            .allowsHitTesting(false)
        }
    }

    private var stopButton: some View {
        Button {
            perform { Task.immediate { await model.stop() } }
        } label: {
            Label {
                Text("停止")
            } icon: {
                Image(systemName: "stop.fill").foregroundStyle(Theme.recording)
            }
        }
        // 按下停止、「收尾中」還沒出現：畫成按下去的樣子，不接受點擊
        .buttonStyle(NeutralButtonStyle(isHeld: model.recorderPhase == .stopping))
        .allowsHitTesting(model.recorderPhase != .stopping)
        .keyboardShortcut(".", modifiers: .command)
        .fixedSize()
    }

    /// 每個動作先問防連點：狀態剛換的 0.5 秒內不算數（快捷鍵也一樣）。
    private func perform(_ action: () -> Void) {
        guard pressGuard.accepts(at: .now) else { return }
        action()
    }
}

/// 主要位置的內容：用看不見的「開始錄音」撐出固定的大小，換成任何內容寬度都不變。
private struct SlotLabel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Label("開始錄音", systemImage: "record.circle").fontWeight(.semibold).hidden()
            content
        }
    }
}

// MARK: - 狀態列

/// 狀態列：左邊只放狀態（錄音、翻譯、音量、費用、來源），右邊只放三個控制項（標記重點、浮動字幕、顯示）。
///
/// 每 0.25 秒更新的時間、音量與費用各自讀 `AppModel`，更新時只重畫那一小塊。
private struct StatusStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 和開始／停止的按鈕同時換：等待未滿 0.3 秒時維持等待之前的樣子
        let shown = model.shownPhase
        let recording = shown == .recording || shown == .paused
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                IndicatorView(.recorder(shown))
                if recording { ElapsedTime() }
            }
            .fixedSize()
            if recording {
                // 翻譯的狀態和錄音分開顯示：翻譯斷線時，錄音仍然持續
                IndicatorView(.engine(model.captions.engineStatus))
                    .layoutPriority(1)
                LevelMeter()
                CostEstimate()
                if !model.sourceDescription.isEmpty {
                    // 空間不夠時最先被截短（上方的來源選單已經寫了來源）
                    Text(model.sourceDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 8)
            if recording {
                Button {
                    model.mark()
                } label: {
                    Label("標記重點", systemImage: "flag")
                }
                .buttonStyle(NeutralButtonStyle())
                .keyboardShortcut("b", modifiers: .command)
                .fixedSize()
            }
            FloatingCaptionsToggle()
            DisplayOptionsButton()
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.ink1)
    }
}

/// 錄音的時間（SF Mono）。
private struct ElapsedTime: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(Format.duration(model.elapsed))
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
    }
}

/// 預估費用（SF Mono、次要灰）。
private struct CostEstimate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(Format.cost(audioSeconds: model.elapsed, provisional: model.settings.showsProvisional))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// 音量：12 格。亮起的格子是磷光綠；超過 85% 時最上面亮起的那一格變黃，超過 95% 變紅。
private struct LevelMeter: View {
    @Environment(AppModel.self) private var model
    private static let bars = 12

    var body: some View {
        // 音量以分貝顯示才看得出變化：-50 dB 到 0 dB
        let decibels = 20 * log10(max(Double(model.level), 0.000_01))
        let fraction = min(1, max(0, (decibels + 50) / 50))
        let lit = Int((fraction * Double(Self.bars)).rounded())
        let peak = fraction > 0.95 ? Theme.danger : fraction > 0.85 ? Theme.mark : Theme.bolt
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < lit ? (index == lit - 1 ? peak : Theme.bolt) : Color.white.opacity(0.1))
                    .frame(width: 3, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

/// 浮動字幕的開關。開著的時候圖示填滿、變綠，底是淡綠色（DESIGN.md 4.10.5 節）。
private struct FloatingCaptionsToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOpen = FloatingCaptions.shared.isOpen
        Button {
            FloatingCaptions.shared.toggle(model: model)
        } label: {
            Label("浮動字幕", systemImage: isOpen ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                .labelStyle(.iconOnly)
                .foregroundStyle(isOpen ? Theme.bolt : Color.primary)
        }
        .buttonStyle(NeutralButtonStyle(isOn: isOpen))
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .help("浮動字幕（⌘⇧F）")
        .accessibilityValue(isOpen ? "開啟" : "關閉")
    }
}

/// 「顯示」：顯示模式、字級與暫定譯文放在彈出視窗裡，狀態列只留一個按鈕。
private struct DisplayOptionsButton: View {
    @State private var shows = false

    var body: some View {
        Button {
            shows.toggle()
        } label: {
            Label {
                Text("顯示")
            } icon: {
                // 中文介面下系統會把這個符號換成「大小」兩個字，和旁邊的「顯示」連在一起讀不通：固定用大小兩個 A 的圖形
                Image(systemName: "textformat.size").environment(\.locale, Locale(identifier: "en"))
            }
        }
        .buttonStyle(NeutralButtonStyle())
        .fixedSize()
        .help("顯示模式、字級、暫定譯文")
        .popover(isPresented: $shows, arrowEdge: .bottom) { DisplayOptions() }
    }
}

private struct DisplayOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            Picker("顯示模式", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("雙語／只看中文／只看英文")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("字級")
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontSize, in: 14...48, step: 2) { Text("字級") }
                    .labelsHidden()
            }
            Toggle(isOn: $settings.showsProvisional) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("顯示暫定譯文")
                    Text("句子還沒說完就先顯示，之後由定稿取代").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .font(.body)
        .controlSize(.regular)
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - 字幕

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
        let marked = model.markedLines
        if lines.isEmpty, liveEnglish.isEmpty {
            // 依錄音的階段說明：按下開始之後就不再叫使用者按開始（判斷在 ThunderUI，有測試）
            let placeholder = CaptionsPlaceholder(phase: model.shownPhase)
            ContentUnavailableView {
                Label {
                    Text(placeholder.title)
                } icon: {
                    PlaceholderSymbol(symbol: placeholder.symbol)
                }
            } description: {
                Text(placeholder.message)
            }
            // 佔滿字幕區：否則整頁會被垂直置中，標題列跑到畫面中間
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VSplitView {
                if mode != .english {
                    CaptionZone(title: "中文", updates: model.captions.updateCount) {
                        if earlier > 0 { EarlierNote(count: earlier) }
                        ForEach(lines) { line in
                            ChineseLine(
                                line: line, showsProvisional: showsProvisional, marked: marked.contains(line.id), size: size)
                        }
                        if showsProvisional, !liveChinese.isEmpty {
                            Text(liveChinese).font(.system(size: size)).foregroundStyle(.secondary).updatingMarker()
                        }
                    }
                    // 行距約 1.45 倍（DESIGN.md 4.10.3 節）
                    .lineSpacing(size * 0.25)
                    .frame(minHeight: 120)
                }
                if mode != .chinese {
                    let englishSize = mode == .english ? size : size * 0.72
                    // 旗子只畫一次：雙語時畫在中文那一行，只看英文時畫在英文這一行
                    let flagsEnglish = mode == .english
                    CaptionZone(title: "English", updates: model.captions.updateCount) {
                        if earlier > 0 { EarlierNote(count: earlier) }
                        ForEach(lines) { line in
                            Text(line.english)
                                .flagged(flagsEnglish && marked.contains(line.id), size: englishSize)
                                .font(.system(size: englishSize))
                                .foregroundStyle(.secondary)
                        }
                        if !liveEnglish.isEmpty {
                            // 正在說的這一行：白 45%，左邊一條綠線
                            Text(liveEnglish.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: englishSize))
                                .foregroundStyle(Theme.speaking)
                                .updatingMarker()
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

/// 一行中文：有定稿用定稿（主要文字色）；沒有的話，允許時顯示暫定譯文（次要灰、左邊一條綠線）；
/// 確定不會有定稿時先顯示英文並標示「未翻譯」。標記過重點的那一行後面有一面黃色旗子。
private struct ChineseLine: View {
    let line: CaptionBoard.Line
    let showsProvisional: Bool
    let marked: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if !line.chinese.isEmpty {
                Text(line.chinese).flagged(marked, size: size)
            } else if line.untranslated {
                // 這一段沒翻到：先顯示英文，結束後補上
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.english).flagged(marked, size: size).foregroundStyle(.secondary)
                    UntranslatedTag()
                }
            } else {
                // 定稿還沒到：這一行還在更新
                let provisional = showsProvisional ? line.provisional : ""
                Text(provisional.isEmpty ? "…" : provisional)
                    .flagged(marked, size: size)
                    .foregroundStyle(.secondary)
                    .updatingMarker()
            }
        }
        .font(.system(size: size))
    }
}

/// 沒翻到的段：橘色的外框標籤（DESIGN.md 4.10.4 節）。
private struct UntranslatedTag: View {
    var body: some View {
        Text("未翻譯")
            .font(.caption)
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.attention.opacity(0.7), lineWidth: 1))
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
                    .buttonStyle(NeutralButtonStyle())
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - 場次資訊與來源

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

// MARK: - 橫幅

/// 頁面頂端的橫幅：發生了什麼、錄音有沒有受影響、該怎麼處理（DESIGN.md 4.1 節）。
struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
            Text(text).textSelection(.enabled)
            Spacer()
            Button("關閉", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.ink1)
    }
}

/// 字幕區空白時的大符號（DESIGN.md 4.10.4）：閃電用 App 圖示的形狀；暫停用系統的暫停符號，灰色（暫停不是可以按的東西，不用綠色）。
private struct PlaceholderSymbol: View {
    let symbol: IndicatorSymbol

    var body: some View {
        if symbol == .pause {
            Image(systemName: "pause.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(height: 44)
        } else {
            BoltShape()
                .fill(Theme.bolt)
                .aspectRatio(BoltShape.aspectRatio, contentMode: .fit)
                .frame(height: 44)
        }
    }
}
