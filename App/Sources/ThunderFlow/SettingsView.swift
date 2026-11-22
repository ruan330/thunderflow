import AppKit
import SwiftUI
import ThunderCore
import ThunderUI

/// 設定頁（DESIGN.md 4.7 節）。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyStatus = ""
    @State private var revealsKey = false
    @State private var isTesting = false
    /// 正在存入或刪除 Key（鑰匙圈可能正跳出授權視窗等使用者回答）：這時不能再按。
    @State private var isWorking = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            if let banner = model.banner {
                Section { Label(banner, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Section("OpenAI API Key") {
                HStack {
                    Group {
                        if revealsKey {
                            TextField("sk-…", text: $keyDraft)
                        } else {
                            SecureField(settings.hasKey ? "已儲存（要更換就貼上新的）" : "sk-…", text: $keyDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(revealsKey ? "隱藏" : "顯示") { revealsKey.toggle() }
                }
                HStack {
                    Button("儲存") { Task { await saveKey() } }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    Button(isTesting ? "測試中…" : "測試") { Task { await testKey() } }.disabled(isTesting || isWorking)
                    Button("刪除", role: .destructive) { Task { await deleteKey() } }.disabled(!settings.hasKey || isWorking)
                    Spacer()
                    Text(keyStatus.isEmpty ? (settings.hasKey ? "鑰匙圈裡已經有 Key" : "還沒有 Key") : keyStatus)
                        .foregroundStyle(.secondary)
                }
                Text("Key 只存在這台電腦的鑰匙圈，不會寫進任何檔案。").font(.caption).foregroundStyle(.secondary)
            }
            Section("字幕") {
                Toggle("顯示暫定譯文（句子還沒說完就先顯示，會被定稿取代）", isOn: $settings.showsProvisional)
                Picker("顯示模式", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                Slider(value: $settings.fontSize, in: 14...48, step: 2) { Text("字級 \(Int(settings.fontSize))") }
            }
            Section("關鍵詞（每一場都會帶上，一行一個：人名、產品名稱、術語）") {
                TextEditor(text: $settings.keywords).font(.body.monospaced()).frame(height: 110)
            }
            Section("會後處理") {
                Toggle("結束後自動產生摘要", isOn: $settings.autoSummary)
            }
            Section("儲存") {
                LabeledContent("資料夾") {
                    HStack {
                        Text(settings.libraryPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("更改…") { chooseLibrary() }
                        Button("在 Finder 中顯示") {
                            try? FileManager.default.createDirectory(at: settings.libraryRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([settings.libraryRoot])
                        }
                    }
                }
            }
            Section("進階") {
                TextField("Base URL", text: $settings.baseURL)
                TextField("轉錄模型", text: $settings.transcriptionModel)
                Picker("轉錄延遲", selection: $settings.delay) {
                    ForEach(["minimal", "low", "medium", "high", "xhigh"], id: \.self) { Text($0).tag($0) }
                }
                TextField("即時翻譯的文字模型", text: $settings.liveTextModel)
                TextField("會後處理的文字模型", text: $settings.postTextModel)
            }
            Section("隱私：哪些資料會送到哪裡") {
                LabeledContent("音訊", value: "錄音中送到 OpenAI（即時轉錄）")
                LabeledContent("英文逐字稿、場次資訊、關鍵詞", value: "錄音中送到 OpenAI（即時翻譯）；結束後產生摘要時再送一次（可以關閉）")
                LabeledContent("其他所有資料", value: "不離開這台電腦")
            }
        }
        .formStyle(.grouped)
        // 表單的底透出內容區的墨黑
        .scrollContentBackground(.hidden)
        .navigationTitle("設定")
    }

    // 鑰匙圈的呼叫可能跳出授權視窗、等使用者回答，所以都在背景做，畫面不會卡住。

    private func saveKey() async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        defer { isWorking = false }
        let result = await Task.detached(priority: .userInitiated) { Result { try Credentials.save(key) } }.value
        switch result {
        case .success:
            model.settings.hasKey = true
            keyDraft = ""
            keyStatus = "已儲存"
            model.banner = nil
            // 存進鑰匙圈的結果在畫面上看不到：用提示說出來
            model.notify(.saved, "已儲存 Key")
        case .failure(let error):
            keyStatus =
                Self.isDenied(error) ? "鑰匙圈沒有允許，所以 Key 沒有存進去。再按一次「儲存」，在鑰匙圈的視窗按「允許」。" : "存不進鑰匙圈：\(error)"
        }
    }

    private func deleteKey() async {
        isWorking = true
        defer { isWorking = false }
        let result = await Task.detached(priority: .userInitiated) { Result { try Credentials.delete() } }.value
        switch result {
        case .success:
            model.settings.hasKey = false
            keyStatus = "已刪除"
        case .failure(let error):
            keyStatus = Self.isDenied(error) ? "鑰匙圈沒有允許，所以 Key 沒有刪除。" : "刪除失敗：\(error)"
        }
    }

    /// 使用者在鑰匙圈的授權視窗按了拒絕或取消（或現在不能跳出視窗）：Key 沒有動，不是壞掉了。
    private static func isDenied(_ error: any Error) -> Bool {
        (error as? KeychainError)?.outcome == .denied
    }

    /// 測試 Key：呼叫免費的 `GET /models`。測的是輸入框裡的 Key；沒有輸入就測已經存好的那一把。
    private func testKey() async {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isTesting = true
        defer { isTesting = false }
        let key: String
        if !draft.isEmpty {
            key = draft
        } else {
            switch await model.loadKey() {
            case .found(let stored):
                key = stored
                model.settings.hasKey = true
            case .missing:
                model.settings.hasKey = false
                keyStatus = "還沒有 Key"
                return
            case .denied:
                keyStatus = "鑰匙圈沒有允許讀取 Key。再按一次「測試」，在鑰匙圈的視窗按「允許」。"
                return
            case .failed(let error):
                keyStatus = "讀不到鑰匙圈裡的 Key：\(error)"
                return
            }
        }
        var request = URLRequest(url: model.settings.textBaseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: keyStatus = "可以使用"
            case 401: keyStatus = "這把 Key 無效"
            case let status?: keyStatus = "服務回應 HTTP \(status)"
            case nil: keyStatus = "沒有收到回應"
            }
        } catch {
            keyStatus = "連不上：\(error.localizedDescription)"
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.libraryPath = url.path
            model.reloadLibrary()
        }
    }
}
