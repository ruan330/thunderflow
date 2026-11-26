import SwiftUI
import ThunderCore
import ThunderUI

/// 手機上唯一的畫面（DESIGN.md 5.10 節）：上面是狀態，中間是字幕，下面是開始／按住停止與標記。
struct LiveScreen: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            StatusBar()
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            CaptionPane()
            Controls()
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $model.showsSettings) { SettingsScreen().environment(model) }
        .sheet(isPresented: $model.showsHandoffs) { HandoffScreen().environment(model) }
    }
}

// MARK: - 狀態列

private struct StatusBar: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle:
                Label("未開始", systemImage: "circle").foregroundStyle(.secondary)
            case .starting:
                ProgressView().controlSize(.small)
                Text("準備中").foregroundStyle(.secondary)
            case .recording:
                Image(systemName: model.interrupted ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(model.interrupted ? Color.orange : Theme.phosphor)
                    .symbolEffect(.pulse, isActive: !model.interrupted)
                Text(PhoneModel.timecode(model.elapsed)).monospacedDigit()
                LevelMeter(level: model.level)
            case .stopping:
                ProgressView().controlSize(.small)
                Text("收尾中").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showsHandoffs = true
            } label: {
                Image(systemName: "tray.and.arrow.up")
            }
            .accessibilityLabel("交給 Mac 的錄音")
            Button {
                model.showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("設定")
        }
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        let shown = CGFloat(min(1, sqrt(Double(max(0, level)))))
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 60, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.phosphor).frame(width: 60 * shown, height: 6)
            }
            .animation(.linear(duration: 0.2), value: shown)
            .accessibilityHidden(true)
    }
}

private struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("關閉")
        }
        .padding(12)
        .background(Theme.panel.opacity(0.9))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 字幕

/// 字幕區：只拿最後幾段出來畫（一場長的錄音有幾千段，DESIGN.md 9.8 節）。新的一段出現就捲到最下面。
private struct CaptionPane: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let board = model.captions.board
        let chinese = CaptionZoneSync.lastParagraphs(
            board: board, marked: model.markedLines,
            options: CaptionZoneOptions(language: .chinese, showsProvisional: true, showsFlags: true, hidesFinalPeriod: true),
            count: 40)
        VStack(spacing: 0) {
            if chinese.isEmpty {
                Placeholder()
            } else {
                Zone(paragraphs: chinese, font: .system(size: 26, weight: .medium), revision: board.revision)
            }
            if model.bilingual {
                Divider()
                let english = CaptionZoneSync.lastParagraphs(
                    board: board, marked: model.markedLines,
                    options: CaptionZoneOptions(language: .english, showsProvisional: false, showsFlags: false), count: 40)
                Zone(paragraphs: english, font: .system(size: 17), revision: board.revision)
                    .frame(maxHeight: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Placeholder: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "captions.bubble").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(model.isRecording ? "聽到第一句話之後，中文字幕會出現在這裡" : "按下「開始錄音」，現場的話會即時翻成中文")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Zone: View {
    let paragraphs: [CaptionParagraph]
    let font: Font
    let revision: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        ParagraphView(paragraph: paragraph, font: font)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: revision) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct ParagraphView: View {
    let paragraph: CaptionParagraph
    let font: Font

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 還在更新的那一段：左邊一條綠線（DESIGN.md 4.10.4 節）
            Rectangle()
                .fill(paragraph.kind == .updating ? Theme.phosphor : Color.clear)
                .frame(width: 3)
            Text(paragraph.text)
                .font(font)
                .foregroundStyle(paragraph.kind == .settled ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if paragraph.kind == .untranslated {
                Text("未翻譯").font(.caption).foregroundStyle(.orange)
            }
            if paragraph.flagged {
                Image(systemName: "flag.fill").foregroundStyle(Theme.flag).accessibilityLabel("標記過")
            }
        }
    }
}

// MARK: - 開始、停止、標記

private struct Controls: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle:
                Button {
                    Task { await model.start() }
                } label: {
                    Label("開始錄音", systemImage: "record.circle")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(.black)
            case .starting, .stopping:
                ProgressView().frame(maxWidth: .infinity, minHeight: 56)
            case .recording:
                Button {
                    model.mark()
                } label: {
                    Label("標記重點", systemImage: "flag")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                HoldToStopButton(duration: 1) { Task { await model.stop() } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.panel)
    }
}

/// 停止要按住約 1 秒才算（DESIGN.md 5.10 節）：手機拿在手上容易誤觸，而錄音只能由使用者停止。
/// 按著的時候紅色從左邊填滿，放開就取消。VoiceOver 可以直接用「停止錄音」的動作。
private struct HoldToStopButton: View {
    let duration: Double
    let action: () -> Void
    @State private var pressing = false
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Capsule().fill(Color.red.opacity(0.22))
            GeometryReader { proxy in
                Capsule().fill(Color.red.opacity(0.75)).frame(width: proxy.size.width * progress)
            }
            Label(pressing ? "放開就取消" : "按住停止", systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            progress = 0
            pressing = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            action()
        } onPressingChanged: { isPressing in
            pressing = isPressing
            withAnimation(isPressing ? .linear(duration: duration) : .easeOut(duration: 0.15)) {
                progress = isPressing ? 1 : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("停止錄音")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
