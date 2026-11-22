import Foundation
import Testing
import ThunderSession

/// 說明是給人看的中文：有中文字、不出現程式裡的名稱，`localizedDescription` 也是同一段說明。
private func expectReadable(_ error: some Error, name: String) {
    let text = String(describing: error)
    #expect(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(name)：要有中文說明，實際是「\(text)」")
    #expect(!text.contains(name), "\(name)：不出現程式裡的名稱，實際是「\(text)」")
    #expect(error.localizedDescription == text, "\(name)：localizedDescription 是「\(error.localizedDescription)」")
}

@Suite("結束處理與錄音的錯誤：說明是給人看的中文")
struct SessionErrorDescriptionTests {
    @Test("結束處理的每一種錯誤：說明是中文，不出現程式裡的名稱")
    func finalizerErrors() {
        let cases: [(SessionFinalizerError, String)] = [
            (.stillRecording, "stillRecording"),
            (.durationMismatch(recorded: 3600, merged: 3590.5), "durationMismatch"),
            (.missingTextModel, "missingTextModel"),
            (.emptyTranscript, "emptyTranscript"),
            (.summaryTimedOut, "summaryTimedOut"),
            (.emptySummary, "emptySummary"),
            (.inProgress, "inProgress"),
        ]
        for (error, name) in cases { expectReadable(error, name: name) }
    }

    @Test("沒有 API Key 而不能產生摘要：說明告訴使用者到「設定」貼上 Key")
    func missingTextModelSaysWhatToDo() {
        let text = String(describing: SessionFinalizerError.missingTextModel)
        #expect(text.contains("API Key"), "實際是「\(text)」")
        #expect(text.contains("設定"), "實際是「\(text)」")
    }

    @Test("合併出來的錄音長度不一致：說明寫出兩個長度，並說原本的錄音還在")
    func durationMismatchShowsLengths() {
        let text = String(describing: SessionFinalizerError.durationMismatch(recorded: 3600, merged: 3590.5))
        #expect(text.contains("3600"), "實際是「\(text)」")
        #expect(text.contains("3590.5"), "實際是「\(text)」")
        #expect(text.contains("還在"), "實際是「\(text)」")
    }

    @Test("錄音的每一種錯誤：說明是中文，不出現程式裡的名稱")
    func recordingErrors() {
        expectReadable(RecordingSessionError.alreadyFinished, name: "alreadyFinished")
        expectReadable(RecordingSessionError.directoryInUse, name: "directoryInUse")
    }
}
