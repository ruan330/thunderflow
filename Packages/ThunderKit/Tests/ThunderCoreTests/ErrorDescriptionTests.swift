import Foundation
import Testing
import ThunderCore

/// 說明是給人看的中文：有中文字、不出現程式裡的名稱，`localizedDescription` 也是同一段說明。
private func expectReadable(_ error: some Error, name: String) {
    let text = String(describing: error)
    #expect(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(name)：要有中文說明，實際是「\(text)」")
    #expect(!text.contains(name), "\(name)：不出現程式裡的名稱，實際是「\(text)」")
    #expect(error.localizedDescription == text, "\(name)：localizedDescription 是「\(error.localizedDescription)」")
}

@Suite("場次檔案與摘要的錯誤：說明是給人看的中文")
struct CoreErrorDescriptionTests {
    @Test("場次是比較新版的 App 寫的：說明是中文，寫出讀到的版本，並請使用者更新")
    func unsupportedSchemaVersion() {
        let error = SessionStoreError.unsupportedSchemaVersion(found: 9, supported: 1)
        expectReadable(error, name: "unsupportedSchemaVersion")
        #expect(String(describing: error).contains("9"))
        #expect(String(describing: error).contains("更新"))
    }

    @Test("文字模型回傳的摘要不是 JSON：說明是中文，不出現程式裡的名稱")
    func summaryNotJSON() {
        expectReadable(SessionSummaryError.notJSON, name: "notJSON")
    }
}

/// 只有 `description` 的錯誤，句尾有句號。
private struct PlainError: Error, CustomStringConvertible {
    var description: String { "這是一個測試用的錯誤。" }
}

@Suite("橫幅用的錯誤說明：App 自己的錯誤用中文說明，系統的錯誤用系統的說明")
struct UserFacingDescriptionTests {
    @Test("App 自己的錯誤：用它的中文說明，不出現程式裡的名稱")
    func ownErrors() {
        let summary: any Error = SessionSummaryError.notJSON
        #expect(summary.userFacingDescription == String(describing: SessionSummaryError.notJSON))
        #expect(!summary.userFacingDescription.contains("notJSON"))
        let http: any Error = TextModelError.http(status: 401, message: "Incorrect API key")
        #expect(http.userFacingDescription == "文字模型回應 HTTP 401：Incorrect API key")
    }

    @Test("系統的錯誤（NSError）：用系統的說明，不出現 Error Domain 與錯誤碼")
    func systemErrors() {
        let error: any Error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let text = error.userFacingDescription
        #expect(!text.isEmpty)
        #expect(error.localizedDescription.hasPrefix(text), "實際是「\(text)」")
        #expect(!text.contains("Error Domain"), "實際是「\(text)」")
        #expect(!text.contains("Code="), "實際是「\(text)」")
    }

    @Test("說明的句尾有句號：拿掉，接在橫幅的句子裡不會出現「。。」")
    func dropsFinalPeriod() {
        let system: any Error = NSError(
            domain: "ThunderFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁碟已滿。"])
        #expect(system.userFacingDescription == "磁碟已滿")
        let english: any Error = NSError(
            domain: "ThunderFlowTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No space left on device."])
        #expect(english.userFacingDescription == "No space left on device")
        let plain: any Error = PlainError()
        #expect(plain.userFacingDescription == "這是一個測試用的錯誤")
    }
}
