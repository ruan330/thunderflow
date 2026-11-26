import SwiftUI

/// 設定（DESIGN.md 5.10 節）：OpenAI API Key、交給 Mac、顯示。
struct SettingsScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var savingKey = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("狀態", value: model.hasKey ? "已設定" : "還沒設定")
                    SecureField("貼上 API Key（sk-…）", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(savingKey ? "儲存中…" : "儲存") {
                        savingKey = true
                        Task {
                            if await model.saveKey(keyDraft) { keyDraft = "" }
                            savingKey = false
                        }
                    }
                    .disabled(savingKey || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasKey {
                        Button("刪除 Key", role: .destructive) { Task { await model.deleteKey() } }
                    }
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    Text("只存在這支手機的 Keychain，不會同步到其他裝置。建議在 OpenAI 另建一把手機專用的 Key：手機掉了可以單獨撤銷。費用和 Mac 一樣，每小時約 US$1.1–1.3。")
                }

                Section {
                    if model.handoff.inboxAvailable == false {
                        Label(PhoneHandoff.unavailable, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        LabeledContent("方式", value: "經由 iCloud 自動交給 Mac")
                    }
                } header: {
                    Text("交給 Mac")
                } footer: {
                    Text("按停止之後，這一場會經由 iCloud 自動交給 Mac 上的 ThunderFlow（同一個 Apple 帳號），交出去之後手機上就不留了。不用選資料夾。")
                }

                Section {
                    Toggle("雙語（中文下面再顯示英文）", isOn: $model.bilingual)
                } header: {
                    Text("顯示")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

/// 交給 Mac 的錄音（DESIGN.md 5.10 節）：哪幾場還沒交給 Mac、哪幾場 Mac 已經收走。
struct HandoffScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let problem = model.handoff.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                Section {
                    if model.handoff.items.isEmpty {
                        Text("目前沒有。按停止之後，錄好的場次會出現在這裡。").foregroundStyle(.secondary)
                    }
                    ForEach(model.handoff.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(PhoneModel.timecode(item.durationSeconds)).font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            StateLabel(state: item.state)
                        }
                    }
                } footer: {
                    Text("逐字稿、摘要、教材與複製路徑都在 Mac 的 ThunderFlow 上：Mac 收走之後，這一場就和在 Mac 上錄的一樣。")
                }
            }
            .navigationTitle("交給 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .refreshable { await model.handoff.refresh() }
            .task { await model.handoff.refresh() }
        }
    }
}

private struct StateLabel: View {
    let state: PhoneHandoff.Item.State

    var body: some View {
        switch state {
        case .onPhone: Label("還在手機上", systemImage: "iphone").foregroundStyle(.orange)
        case .inInbox: Label("等 Mac 收", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
        case .collected: Label("Mac 已收走", systemImage: "checkmark.circle").foregroundStyle(Theme.phosphor)
        }
    }
}
