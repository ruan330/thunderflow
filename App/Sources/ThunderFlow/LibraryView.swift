import AVFoundation
import AppKit
import Observation
import SwiftUI
import ThunderCore
import ThunderSession
import ThunderUI

/// 過去錄音（DESIGN.md 4.5、4.6 節）：左邊是清單，右邊是選中那一場的摘要、逐字稿與播放器。
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                TextField("搜尋標題、摘要…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "還沒有錄音", systemImage: "tray",
                        description: Text("到「即時翻譯」按下開始錄音，結束後會出現在這裡。"))
                    .frame(maxHeight: .infinity)
                } else {
                    List(model.filteredSessions, selection: $model.selectedSession) { item in
                        SessionRow(item: item, progress: model.processing[item.id])
                            .tag(item.id)
                            .contextMenu {
                                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([item.directory.url]) }
                                Button("重新產生摘要") { model.regenerateSummary(item) }
                                Divider()
                                Button("刪除（移到垃圾桶）", role: .destructive) { model.delete(item) }
                            }
                    }
                    // 清單的底透出內容區的墨黑；選取的列維持系統的樣子
                    .scrollContentBackground(.hidden)
                }
            }
            // 兩邊都撐滿高度：左右分欄的高度取兩邊內容的理想高度。沒選場次時右邊只有一個小提示，
            // 不撐滿的話整個分欄只有提示那麼高、被垂直置中，清單只看得到一兩列（點一場之後詳細頁撐開才恢復）。
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)

            if let item = model.sessions.first(where: { $0.id == model.selectedSession }) {
                SessionDetailView(item: item)
                    // 用場次的 id 識別，不用資料夾的位置：摘要做好之後自動命名會改資料夾的名稱，
                    // 用位置識別的話整個詳細頁會重建，播放停掉、分頁與捲動的位置都回到原點
                    .id(item.id)
                    .frame(minWidth: 480, maxHeight: .infinity)
            } else {
                ContentUnavailableView("選一場錄音", systemImage: "doc.text.magnifyingglass")
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("過去錄音")
        .onAppear { model.reloadLibrary() }
    }
}

struct SessionRow: View {
    let item: SessionLibrary.Item
    let progress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.meta.title.isEmpty ? "未命名" : item.meta.title).font(.headline).lineLimit(1)
                Spacer()
                // 只有例外才掛狀態標籤；正常完成的不掛（DESIGN.md 4.5 節）
                if let badge = Indicator.sessionBadge(item.meta, progress: progress) {
                    IndicatorView(badge).font(.caption).layoutPriority(1)
                }
            }
            Text("\(Format.date(item.meta.startedAt)) · \(Format.duration(item.meta.durationSeconds))")
                .font(.caption).foregroundStyle(.secondary)
            if !item.meta.oneLiner.isEmpty {
                Text(item.meta.oneLiner).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// 單場詳細頁：摘要與逐字稿兩個分頁，底部是播放器。點段落或章節的時間就跳到錄音的那個位置。
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let item: SessionLibrary.Item
    /// 分頁：只在第一次讀到內容時決定先看哪一頁（判斷在 ThunderUI，有測試）。
    @State private var tabs = SessionDetailTabs()
    @State private var blocks: [TranscriptBlock] = []
    @State private var summary: SessionSummary?
    @State private var player = PlayerModel()
    @State private var find = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $tabs.selected) {
                ForEach(SessionDetailTabs.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 和標題的左邊對齊
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Group {
                switch tabs.selected {
                case .summary: summaryTab
                case .transcript: transcriptTab
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            PlayerBar(player: player, processing: model.processing[item.id] != nil && !player.isReady)
        }
        .task(id: reloadKey) { load() }
        .onDisappear { player.stop() }
    }

    /// 這一場的內容有變（處理進度、摘要完成）或資料夾換了位置（自動命名）就重新讀檔。
    private var reloadKey: String {
        "\(item.meta.completedSteps.count)-\(item.meta.oneLiner.count)-\(model.processing[item.id] ?? "")-\(item.directory.url.path)"
    }

    private func load() {
        let directory = item.directory
        blocks = (try? TranscriptBlocks.read(directory.blocksURL)) ?? []
        summary = try? SessionSummary.read(directory.summaryDataURL)
        // 有摘要時先看摘要，但只在第一次讀到內容時：之後摘要才做好，也不把正在讀逐字稿的人切走
        tabs.contentLoaded(hasSummary: summary != nil)
        player.load(directory.recordingURL)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.meta.title.isEmpty ? "未命名" : item.meta.title).font(.title2.bold()).lineLimit(2)
                Spacer()
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([item.directory.url]) }
                Menu {
                    Button("重新產生摘要") { model.regenerateSummary(item) }
                    Button("複製全文（雙語）") {
                        copy(blocks.map { "\($0.en)\n\($0.zh)" }.joined(separator: "\n\n"), as: "雙語全文")
                    }
                    Button("複製全文（中文）") { copy(blocks.map(\.zh).joined(separator: "\n\n"), as: "中文全文") }
                    Button("複製全文（英文）") { copy(blocks.map(\.en).joined(separator: "\n\n"), as: "英文全文") }
                    Divider()
                    Button("刪除（移到垃圾桶）", role: .destructive) { model.delete(item) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .fixedSize()
            }
            Text(infoLine).font(.callout).foregroundStyle(.secondary)
            if let note = integrityNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let progress = model.processing[item.id] {
                Label(progress, systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var infoLine: String {
        let meta = item.meta
        var parts = [
            meta.startedAt.formatted(date: .numeric, time: .shortened), Format.duration(meta.durationSeconds), meta.source, meta.engine,
        ]
        if meta.billedAudioSeconds > 0 { parts.append(Format.cost(audioSeconds: meta.billedAudioSeconds, provisional: true)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 這一場有掉音、有沒有字幕的區段、或有沒翻到的段時，顯示一行說明。
    private var integrityNote: String? {
        let integrity = item.meta.integrity
        var notes: [String] = []
        if integrity.ringDroppedSamples > 0 || integrity.captureDiscontinuities > 0 {
            notes.append("錄音可能有掉音（\(integrity.ringDroppedSamples) 個樣本、\(integrity.captureDiscontinuities) 次中斷）")
        }
        if integrity.unrecordedSeconds > 0 {
            let length =
                integrity.unrecordedSeconds < 60
                ? String(format: "%.1f 秒", integrity.unrecordedSeconds) : Format.duration(integrity.unrecordedSeconds)
            notes.append("有 \(length) 的聲音因為錄音檔寫不進去（例如磁碟滿了）而沒有錄到")
        }
        if integrity.untranslatedSeconds >= 1 { notes.append("有 \(Format.duration(integrity.untranslatedSeconds)) 的聲音沒有字幕") }
        if integrity.untranslatedSegments > 0 { notes.append("有 \(integrity.untranslatedSegments) 段沒有翻譯") }
        if item.meta.recovered { notes.append("這一場是從異常結束中復原的") }
        return notes.isEmpty ? nil : notes.joined(separator: "；")
    }

    @ViewBuilder private var summaryTab: some View {
        if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(summary.oneLiner).font(.title3)
                    if !summary.keyPoints.isEmpty {
                        section("重點") {
                            ForEach(summary.keyPoints, id: \.self) { Label($0, systemImage: "circle.fill").labelStyle(BulletStyle()) }
                        }
                    }
                    if !summary.chapters.isEmpty {
                        section("章節") {
                            ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                                Button {
                                    player.seek(to: chapter.startSec, play: true)
                                } label: {
                                    ChapterRow(chapter: chapter)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !summary.glossary.isEmpty {
                        section("名詞對照") {
                            ForEach(Array(summary.glossary.enumerated()), id: \.offset) { _, term in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(term.en).bold().frame(width: 200, alignment: .leading)
                                    Text(term.zh)
                                }
                            }
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        section("待辦事項") {
                            ForEach(summary.actionItems, id: \.self) { Label($0, systemImage: "square").labelStyle(BulletStyle()) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
            }
        } else if item.meta.failedSteps.contains("summary") {
            ContentUnavailableView {
                Label("摘要沒有產生成功", systemImage: "exclamationmark.triangle")
            } description: {
                Text("錄音與逐字稿不受影響。")
            } actions: {
                Button("重新產生摘要") { model.regenerateSummary(item) }
            }
        } else if model.processing[item.id] != nil {
            ContentUnavailableView("摘要產生中…", systemImage: "hourglass")
        } else {
            ContentUnavailableView {
                Label("這一場沒有摘要", systemImage: "doc.text")
            } actions: {
                Button("產生摘要") { model.regenerateSummary(item) }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        if blocks.isEmpty {
            ContentUnavailableView(
                model.processing[item.id] != nil ? "逐字稿處理中…" : "這一場沒有逐字稿", systemImage: "text.alignleft")
        } else {
            VStack(spacing: 0) {
                TextField("在這一場裡搜尋…", text: $find)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(visibleBlocks) { block in
                            Button {
                                player.seek(to: block.start, play: true)
                            } label: {
                                BlockView(block: block, isCurrent: block.id == currentBlockID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var visibleBlocks: [TranscriptBlock] {
        let query = find.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return blocks }
        return blocks.filter { $0.en.localizedCaseInsensitiveContains(query) || $0.zh.localizedCaseInsensitiveContains(query) }
    }

    /// 播放中的位置落在哪一個段落。
    private var currentBlockID: Int? {
        guard player.isReady, player.position > 0 else { return nil }
        return blocks.last { $0.start <= player.position }?.id
    }

    /// 複製全文，並用提示說出複製了什麼、多少字（結果在畫面上看不到）。
    private func copy(_ text: String, as name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.notify(.copied, "已複製\(name)（\(text.count.formatted()) 字）")
    }
}

/// 逐字稿的一個段落。點下去就從這裡播放：滑過時加底色、時間碼旁出現播放符號；
/// 目前播放的段落左邊一條綠線（DESIGN.md 4.10.5 節）。
struct BlockView: View {
    let block: TranscriptBlock
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Format.timecode(block.start)).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.bolt)
                // 一直佔著位置，只在滑過時看得到：旁邊的旗子不會跟著移動
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.bolt).opacity(hovering ? 1 : 0)
                if block.marked { Image(systemName: "flag.fill").font(.caption).foregroundStyle(Theme.mark) }
            }
            if block.zh.isEmpty {
                Text("（這一段沒有中文）").foregroundStyle(.tertiary)
            } else {
                Text(block.zh).font(.body)
            }
            Text(block.en).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.white.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Theme.bolt).frame(width: 3).padding(.vertical, 6).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// 摘要的一個章節：和逐字稿段落一樣，滑過時加底色、時間碼旁出現播放符號，點下去就從這裡播放。
private struct ChapterRow: View {
    let chapter: SessionSummary.Chapter
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                Text(Format.timecode(chapter.startSec)).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.bolt)
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Theme.bolt).opacity(hovering ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title).font(.headline)
                Text(chapter.summary).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            Color.white.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        // 底色往外多畫一點，文字和上面的標題仍然對齊
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

struct BulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// 錄音的播放：播放／暫停、拖曳、速度、前後跳 15 秒。
@MainActor
@Observable
final class PlayerModel {
    private(set) var isReady = false
    private(set) var isPlaying = false
    var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: Float = 1 { didSet { player?.rate = rate } }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// 打開這一場的錄音檔（還沒有錄音檔時下次再試）。每一場有自己的播放器（詳細頁以場次識別）。
    ///
    /// 已經打開了就不再換：資料夾改名或搬移（例如摘要做好之後自動命名）時，打開的檔案跟著資料夾走，
    /// 播放、跳轉、停止後再播都照常（實測），所以不重新打開，播放不會中斷，位置也不會回到開頭。
    func load(_ url: URL) {
        guard player == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path), let player = try? AVAudioPlayer(contentsOf: url) else {
            isReady = false
            return
        }
        player.enableRate = true
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        isReady = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            player.rate = rate
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to seconds: TimeInterval, play: Bool = false) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), max(0, duration - 0.1))
        position = player.currentTime
        if play, !player.isPlaying { toggle() }
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
    }

    /// 只在播放中更新位置；暫停時不留計時器。
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

struct PlayerBar: View {
    @Bindable var player: PlayerModel
    let processing: Bool

    var body: some View {
        HStack(spacing: 12) {
            if player.isReady {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    player.skip(-15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                Button {
                    player.skip(15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                Slider(
                    value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                Text("\(Format.duration(player.position)) / \(Format.duration(player.duration))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Picker("速度", selection: $player.rate) {
                    Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2))
                }
                .labelsHidden()
                .frame(width: 80)
            } else {
                Label(processing ? "錄音處理中…" : "這一場沒有錄音檔", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
