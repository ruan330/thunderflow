import Foundation

extension Error {
    /// 給人看的錯誤說明，放進橫幅的句子裡（DESIGN.md 4.1 節）。
    ///
    /// - App 自己的錯誤：用它的中文說明（`LocalizedError` 或 `CustomStringConvertible`），不會出現程式裡的名稱。
    /// - 系統的錯誤（`NSError`，例如檔案讀寫失敗）：用系統的說明（`localizedDescription`），
    ///   不會出現「Error Domain=… Code=… UserInfo=…」。
    /// - 句尾的句號拿掉：呼叫的人接著寫下一句時，不會出現「。。」。
    public var userFacingDescription: String {
        let errorType = type(of: self)
        let text: String
        if let localized = self as? any LocalizedError, let description = localized.errorDescription {
            text = description
        } else if !(errorType is NSError.Type), errorType is any CustomStringConvertible.Type {
            // NSError 也有 description，但那是給程式設計師看的（Error Domain=…），所以只用 Swift 自己的錯誤的說明。
            // 看型別本身有沒有說明：值的轉型在編譯時會被當成一定成功（每個錯誤都能轉成 NSError）
            text = String(describing: self)
        } else {
            text = (self as NSError).localizedDescription
        }
        return droppingFinalPeriod(text)
    }
}

private func droppingFinalPeriod(_ text: String) -> String {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = text.last, "。.．".contains(last) {
        text.removeLast()
    }
    return text
}
