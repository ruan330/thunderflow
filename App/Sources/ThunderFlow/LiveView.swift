import AppKit
import SwiftUI
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderUI
import UniformTypeIdentifiers

/// 即時翻譯頁（DESIGN.md 4.3 節）：上面是場次資訊與開始／停止，中間是狀態，下面是中文與英文兩區字幕。
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if let prompt = model.interruptedPrompt {
                InterruptedSessionsBanner(
                    prompt: prompt, finish: { model.finishInterruptedSessions() }, later: { model.postponeInterruptedSessions() })
                Hairline()
            }
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
            // 工作坊教材（D34）：教材放在這一場的資料夾裡，所以開始錄音之後才能下載
            WorkshopButton(sessionID: model.recordingID, directory: model.recordingDirectory)
            Spacer()
            // 錄音中、暫停中也能換來源，接著錄同一場（D35）
            SourcePicker()
                .disabled(!model.sourceMenuEnabled)
            // 開始、暫停、停止永遠不被擠（錄音中左邊多了「停止」）：空間不夠時，先截短標題與其他按鈕上的字
            TransportControls()
                .fixedSize()
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
/// 不會出現在主要位置，所以剛按下開始時手快多點一下，最多是暫停。狀態剛換的 0.5 秒內不接受點擊（`AppModel.press`，
/// 和「錄音」選單共用）；開始或停止在 0.3 秒內完成時不顯示「準備中」「收尾中」：按下的按鈕維持按下的樣子，直接換成結果
/// （`RecorderPhase.shown`；計時在 `AppModel`，狀態列與字幕區共用同一個）。位置的判斷都在 `TransportSlots`。
/// 快捷鍵（⌘N、⌘.）在「錄音」選單（`RecordingMenu`），這裡不另外設定。
private struct TransportControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    }

    @ViewBuilder private func mainSlot(_ main: TransportSlots.Main, phase: RecorderPhase) -> some View {
        switch main {
        case .start:
            Button {
                model.press { Task.immediate { await model.start() } }
            } label: {
                SlotLabel { Label("開始錄音", systemImage: "record.circle") }
            }
            .buttonStyle(PrimaryButtonStyle(isHeld: phase == .starting))
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
                model.press { model.togglePause() }
            } label: {
                SlotLabel { Label("暫停", systemImage: "pause.fill") }
            }
            .buttonStyle(NeutralButtonStyle())
            // 按下停止、「收尾中」還沒出現：維持原樣，不接受點擊
            .allowsHitTesting(phase == .recording)
        case .resume:
            Button {
                model.press { model.togglePause() }
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
            model.press { Task.immediate { await model.stop() } }
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
        .fixedSize()
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

/// 狀態列：左邊只放狀態（錄音、翻譯、音量、費用、來源），右邊只放控制項（錄音中的標記重點與複製逐字稿路徑、浮動字幕、顯示）。
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
                // 快捷鍵 ⌘B 在「錄音」選單，任何一頁都能用
                Button {
                    model.mark()
                } label: {
                    Label("標記重點", systemImage: "flag")
                }
                .buttonStyle(NeutralButtonStyle())
                .help("標記重點（⌘B）")
                .fixedSize()
                // 給 AI agent 讀的即時逐字稿（D34）：按停止之後改到詳細頁複製 transcript.md 的路徑
                // 空間不夠時只留圖示，不擠掉左邊的狀態（滑鼠移上去看得到名稱）
                Button {
                    model.copyLiveTranscriptPath()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("複製逐字稿路徑", systemImage: "doc.on.clipboard").fixedSize()
                        Label("複製逐字稿路徑", systemImage: "doc.on.clipboard").labelStyle(.iconOnly).fixedSize()
                    }
                }
                .buttonStyle(NeutralButtonStyle())
                .help("複製逐字稿路徑：即時逐字稿（live-transcript.txt），給 AI agent 讀")
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
        // 快捷鍵 ⌘⇧F 在「錄音」選單，任何一頁都能用
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
///
/// 這裡只看「有沒有字幕」與顯示的設定：字幕每一次更新不經過 SwiftUI，由兩區自己的文字元件處理
/// （`CaptionZone`，HANDOVER.md P9）。整場的字幕都在，錄音中可以捲回最前面。
struct CaptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.captions.hasCaptions {
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
            let mode = model.settings.displayMode
            let size = CGFloat(model.settings.fontSize)
            let showsProvisional = model.settings.showsProvisional
            VSplitView {
                if mode != .english {
                    // 行距約 1.45 倍（DESIGN.md 4.10.3 節）
                    CaptionZone(
                        style: CaptionZoneStyle(
                            title: "中文",
                            options: CaptionZoneOptions(
                                language: .chinese, showsProvisional: showsProvisional, showsFlags: true, hidesFinalPeriod: true),
                            fontSize: size, lineSpacing: size * 0.25)
                    )
                    .frame(minHeight: 120)
                }
                if mode != .chinese {
                    // 旗子只畫一次：雙語時畫在中文那一行，只看英文時畫在英文這一行
                    CaptionZone(
                        style: CaptionZoneStyle(
                            title: "English",
                            options: CaptionZoneOptions(
                                language: .english, showsProvisional: showsProvisional, showsFlags: mode == .english),
                            fontSize: mode == .english ? size : size * 0.72, lineSpacing: 0)
                    )
                    .frame(minHeight: 90)
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
            // 記住的麥克風不在清單裡（拔掉了，或清單還沒讀到）：保留這個選項，選單才不會變成無效的。
            // 開始時改用系統預設的輸入裝置並說明；接回來之後又會用它
            if case .microphone(let uid) = model.source, !uid.isEmpty, !model.devices.contains(where: { $0.uid == uid }) {
                Text(model.devices.isEmpty ? "先前選擇的麥克風" : "先前選擇的麥克風（找不到，會改用系統預設的）")
                    .tag(model.source)
            }
            if case .file(let url) = model.source {
                Text("音檔：\(url.lastPathComponent)").tag(AppModel.SourceChoice.file(url))
            }
        }
        .frame(maxWidth: 260)
        .onChange(of: model.source) { _, new in model.sourceChanged(to: new) }
        .help(model.isRecording ? "換來源之後接著錄同一場" : "收音的來源")
        .contextMenu {
            Button("重新整理裝置清單") { model.refreshDevices() }
            Button("用音檔當來源…（測試用）") { chooseFile() }.disabled(!model.offersFileSource)
        }
        Button {
            chooseFile()
        } label: {
            Image(systemName: "doc.badge.plus")
        }
        .disabled(!model.offersFileSource)
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

/// 上次沒有正常結束的場次（當機、被強制結束）：問要現在結束並產生逐字稿，還是稍後再決定（D26）。
/// 和其他橫幅一樣放在頁面頂端，不擋任何操作；好幾場時一次問。
struct InterruptedSessionsBanner: View {
    let prompt: InterruptedSessionPrompt
    let finish: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
            Text(prompt.message).textSelection(.enabled)
            Spacer()
            Button(InterruptedSessionPrompt.laterLabel, action: later)
            Button(InterruptedSessionPrompt.finishLabel, action: finish).buttonStyle(.borderedProminent)
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
