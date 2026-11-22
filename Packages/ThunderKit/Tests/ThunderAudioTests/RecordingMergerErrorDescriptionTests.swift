import Foundation
import Testing
import ThunderAudio

@Suite("合併錄音的錯誤：說明是給人看的中文")
struct RecordingMergerErrorDescriptionTests {
    @Test("合併錄音的每一種錯誤：說明是中文，不出現程式裡的名稱")
    func readable() {
        let cases: [(RecordingMergerError, String)] = [(.noAudio, "noAudio"), (.conversionFailed, "conversionFailed")]
        for (error, name) in cases {
            let text = String(describing: error)
            #expect(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(name)：要有中文說明，實際是「\(text)」")
            #expect(!text.contains(name), "\(name)：不出現程式裡的名稱，實際是「\(text)」")
            #expect(error.localizedDescription == text, "\(name)：localizedDescription 是「\(error.localizedDescription)」")
        }
    }
}
