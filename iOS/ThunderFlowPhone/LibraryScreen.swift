import SwiftUI
import ThunderCore
import ThunderSession
import ThunderUI

/// 過去錄音（DESIGN.md 5.10 節，D38）：上面是 Mac 還沒收到的場次（還在手機上、或在收件匣裡），下面是 Mac 上的紀錄。
/// 只能看：逐字稿、摘要、播放錄音。改名、刪除、重新產生摘要、教材都在 Mac 上。
struct LibraryScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.libraryPath) {
            List {
                if let problem = model.handoff.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                // 已經在 Mac 的紀錄裡的就不再列（Mac 收進來了，只是收件匣的那一份還沒同步刪掉）
                let collected = Set(model.library.items.map(\.id))
                let waiting = model.handoff.items.filter { $0.state != .collected && !collected.contains($0.id) }
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Text(PhoneModel.timecode(item.durationSeconds)).font(.caption).foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                HandoffStateLabel(state: item.state)
                            }
                        }
                    } header: {
                        Text("Mac 還沒收到")
                    } footer: {
                        Text("Mac 收進來、做完摘要之後，會出現在下面。")
                    }
                }
                librarySection
            }
            .navigationTitle("過去錄音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .navigationDestination(for: URL.self) { folder in
                if let item = model.library.item(at: folder) {
                    SessionDetailScreen(item: item)
                } else {
                    ContentUnavailableView("找不到這一場", systemImage: "questionmark.folder")
                }
            }
            .refreshable { await model.refreshLibrary() }
            .task { await model.refreshLibrary() }
        }
    }

    @ViewBuilder private var librarySection: some View {
        let library = model.library
        Section {
            if let problem = library.problem {
                Label(problem, systemImage: "icloud.slash").foregroundStyle(.orange)
            } else if library.loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("從 iCloud 讀取…").foregroundStyle(.secondary)
                }
            } else if library.items.isEmpty {
                Text("還沒有過去錄音。Mac 收進來、做完摘要的場次會出現在這裡。").foregroundStyle(.secondary)
            }
            ForEach(library.items, id: \.directory.url) { item in
                NavigationLink(value: item.directory.url) { SessionRow(item: item) }
            }
            if library.pending > 0 {
                Label("還有 \(library.pending) 場沒從 iCloud 下載下來（沒有網路？）。往下拉可以重新整理。", systemImage: "icloud.and.arrow.down")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mac 上的紀錄")
        } footer: {
            Text("手機上只能看。改名、刪除、重新產生摘要與教材，在 Mac 的 ThunderFlow 上做。")
        }
    }
}

private struct SessionRow: View {
    let item: SessionLibrary.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.meta.displayTitle).font(.body.weight(.semibold)).lineLimit(2)
            HStack(spacing: 6) {
                Text(item.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(PhoneModel.duration(item.meta.durationSeconds))
                if item.meta.state != .complete {
                    Text("·")
                    Text("Mac 處理中").foregroundStyle(Theme.phosphor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct HandoffStateLabel: View {
    let state: PhoneHandoff.Item.State

    var body: some View {
        switch state {
        case .onPhone: Label("還在手機上", systemImage: "iphone").foregroundStyle(.orange)
        case .inInbox: Label("等 Mac 收", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
        case .collected: Label("Mac 已收走", systemImage: "checkmark.circle").foregroundStyle(Theme.phosphor)
        }
    }
}

// MARK: - 一場的詳細頁

/// 一場的內容：摘要與雙語逐字稿（和 Mac 的詳細頁同樣的資料），下面是播放錄音。
/// 點章節或段落就從那裡播放（錄音按播放時才從 iCloud 下載）。
struct SessionDetailScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var detail: PhoneSessionDetail
    @State private var player = PhonePlayer()

    init(item: SessionLibrary.Item) {
        _detail = State(initialValue: PhoneSessionDetail(item: item))
    }

    private var item: SessionLibrary.Item { detail.item }
    /// 錄音中不能播放：麥克風占著音訊。
    private var canPlay: Bool { model.phase == .idle }

    var body: some View {
        @Bindable var detail = detail
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.meta.displayTitle).font(.title3.bold())
                    Text(infoLine).font(.footnote).foregroundStyle(.secondary)
                }
                Picker("", selection: $detail.tabs.selected) {
                    ForEach(SessionDetailTabs.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let problem = detail.problem {
                    Label(problem, systemImage: "icloud.slash").font(.callout).foregroundStyle(.orange)
                }
                if detail.loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("從 iCloud 下載…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    switch detail.tabs.selected {
                    case .summary: summaryTab
                    case .transcript: transcriptTab
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { PlayerControls(player: player, canPlay: canPlay, play: { play(from: nil) }) }
        .task {
            await detail.load()
            // 自動測試的截圖：指定先看哪一頁
            if let page = UserDefaults.standard.string(forKey: "selfTestLibraryOpen"),
                let tab = SessionDetailTabs.Tab.allCases.first(where: { "\($0)" == page })
            {
                detail.tabs.selected = tab
            }
        }
        .onDisappear { player.stop() }
    }

    private var infoLine: String {
        let meta = item.meta
        return [meta.startedAt.formatted(date: .numeric, time: .shortened), PhoneModel.timecode(meta.durationSeconds), meta.source]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func play(from seconds: Double?) {
        guard canPlay else { return }
        Task {
            if player.state != .ready { await player.prepareAndPlay(item.directory.recordingURL) }
            if let seconds, player.state == .ready { player.seek(to: seconds) }
        }
    }

    @ViewBuilder private var summaryTab: some View {
        if let summary = detail.summary {
            VStack(alignment: .leading, spacing: 18) {
                if !summary.oneLiner.isEmpty { Text(summary.oneLiner).font(.body.weight(.medium)) }
                if !summary.keyPoints.isEmpty {
                    section("重點") {
                        ForEach(summary.keyPoints, id: \.self) { point in Bullet(text: point, symbol: "circle.fill") }
                    }
                }
                if !summary.chapters.isEmpty {
                    section("章節") {
                        ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                            Button {
                                play(from: chapter.startSec)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(PhoneModel.timecode(chapter.startSec))
                                        .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.phosphor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chapter.title).font(.subheadline.weight(.semibold))
                                        if !chapter.summary.isEmpty {
                                            Text(chapter.summary).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !summary.glossary.isEmpty {
                    section("名詞對照") {
                        ForEach(Array(summary.glossary.enumerated()), id: \.offset) { _, term in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(term.en).font(.subheadline.weight(.semibold))
                                Text(term.zh).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !summary.actionItems.isEmpty {
                    section("待辦事項") {
                        ForEach(summary.actionItems, id: \.self) { action in Bullet(text: action, symbol: "square") }
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            ContentUnavailableView(
                item.meta.state != .complete ? "Mac 還在產生摘要" : "這一場沒有摘要", systemImage: "doc.text",
                description: Text(item.meta.state != .complete ? "做好之後會出現在這裡。" : "可以在 Mac 上產生摘要。"))
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        if detail.blocks.isEmpty {
            ContentUnavailableView("這一場沒有逐字稿", systemImage: "text.alignleft")
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(detail.blocks) { block in
                    Button {
                        play(from: block.start)
                    } label: {
                        BlockRow(block: block, bilingual: model.bilingual)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct Bullet: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 6)).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// 逐字稿的一個段落：時間、標記的旗子、中文，雙語時下面是英文。
private struct BlockRow: View {
    let block: TranscriptBlock
    let bilingual: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(PhoneModel.timecode(block.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.phosphor)
                if block.marked { Image(systemName: "flag.fill").font(.caption).foregroundStyle(Theme.flag) }
            }
            if block.zh.isEmpty {
                Text("（這一段沒有中文）").foregroundStyle(.tertiary)
            } else {
                Text(block.zh).font(.body)
            }
            if bilingual || block.zh.isEmpty {
                Text(block.en).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 下面的播放列：還沒下載時是「播放錄音」，下載中轉圈，之後是播放、前後 15 秒與進度。
private struct PlayerControls: View {
    @Bindable var player: PhonePlayer
    let canPlay: Bool
    let play: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            switch player.state {
            case .idle:
                Button(action: play) { Label("播放錄音", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(!canPlay)
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("從 iCloud 下載錄音…").foregroundStyle(.secondary)
                }
            case .failed(let reason):
                Button(action: play) { Label(reason, systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(!canPlay)
            case .ready:
                HStack(spacing: 22) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                    }
                    .disabled(!canPlay && !player.isPlaying)
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                }
                .font(.title3)
                Slider(
                    value: Binding(get: { player.position }, set: { player.seek(to: $0, play: false) }),
                    in: 0...max(player.duration, 1))
                HStack {
                    Text(PhoneModel.timecode(player.position))
                    Spacer()
                    Text(PhoneModel.timecode(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if !canPlay, !player.isPlaying {
                Text("錄音中不能播放").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}
