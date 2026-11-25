import AppKit
import SwiftUI
import ThunderCore
import ThunderSession
import ThunderUI

/// 「教材」按鈕（DESIGN.md 4.3、4.6 節，D34）：按下去打開 `WorkshopPanel`。即時翻譯頁（錄音中）與詳細頁共用。
struct WorkshopButton: View {
    /// 這一場（`SessionMeta.id`）與它現在所在的資料夾；nil 是現在不能下載（還沒開始錄音）。
    let sessionID: UUID?
    let directory: SessionDirectory?
    /// 過去錄音的 `session.json`（判斷路徑會不會再變）；錄音中是 nil。
    var meta: SessionMeta?
    @State private var shows = false

    var body: some View {
        Button {
            shows.toggle()
        } label: {
            Label("教材", systemImage: "books.vertical")
        }
        .disabled(sessionID == nil)
        .help(sessionID == nil ? "開始錄音之後才能下載教材" : "下載工作坊教材、複製教材資料夾的路徑（給 AI agent 讀）")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            if let sessionID, let directory {
                WorkshopPanel(sessionID: sessionID, directory: directory, meta: meta)
            }
        }
    }
}

/// 工作坊教材：輸入網址下載到這一場的 `workshop/`、看下載過哪些、複製 `workshop/` 的路徑。
///
/// 下載交給 workshop-archive（`WorkshopDownloader`）；每次下載都另存一份，舊的不刪。
/// 能不能複製路徑由 `AgentPaths` 判斷（有測試）：過去錄音要等路徑不會再變。
struct WorkshopPanel: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    let directory: SessionDirectory
    let meta: SessionMeta?
    @State private var address = ""

    var body: some View {
        let downloader = model.workshopDownloader
        let installed = downloader.isToolInstalled
        let downloads = model.workshopDownloads[sessionID] ?? []
        // 每次重畫都重新看資料夾：下載好的教材一放進去，清單與「複製教材路徑」就跟著出現
        let materials = Self.materials(in: directory)
        let paths = meta.map { AgentPaths.finished(directory, meta: $0) } ?? AgentPaths.recording(directory)
        VStack(alignment: .leading, spacing: 12) {
            Text("工作坊教材").font(.headline)
            HStack(spacing: 8) {
                TextField("教材網址（https://…）", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)
                Button("下載", action: download)
                    .disabled(!installed || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !installed {
                Label("找不到 workshop-archive（\(downloader.tool.path)），請先安裝", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !materials.isEmpty || !downloads.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(materials, id: \.self) { name in
                        Label(name, systemImage: "books.vertical").lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(downloads) { download in row(download) }
                }
            }
            if let folder = paths.workshop {
                HStack(spacing: 8) {
                    Button("複製教材路徑") { model.copyPath(folder, as: "教材資料夾") }
                    Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
            } else if !materials.isEmpty, paths.waitsForTitle {
                Text("這一場還沒有標題：自動命名之後才能複製教材路徑（資料夾會改名）。").foregroundStyle(.secondary)
            }
            Text("只抓公開的教材；要登入的頁面抓不到，可以把網址交給 AI agent。每次下載都另存一份，舊的不刪。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 460)
    }

    @ViewBuilder private func row(_ download: AppModel.WorkshopDownload) -> some View {
        switch download.state {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(download.address).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let progress, progress.plannedPages > 0 {
                    Text("\(progress.savedPages)／\(progress.plannedPages) 頁").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("下載中").foregroundStyle(.secondary)
                }
                Button("取消") { model.cancelWorkshopDownload(download.id) }
            }
        case .failed(let reason):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(download.address).lineLimit(1).truncationMode(.middle)
                    Text(reason).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Button {
                    model.removeWorkshopDownload(download.id, of: sessionID)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("移除這一筆")
            }
        }
    }

    private func download() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.workshopDownloader.isToolInstalled else { return }
        model.downloadWorkshop(trimmed, for: sessionID)
        address = ""
    }

    /// 這一場下載過的教材（`workshop/` 裡的子資料夾），依名稱排序。
    static func materials(in directory: SessionDirectory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.workshopURL.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }
}
