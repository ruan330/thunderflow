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
