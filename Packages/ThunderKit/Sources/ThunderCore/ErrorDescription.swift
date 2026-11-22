import Foundation

extension Error {
    /// 給人看的錯誤說明，放進橫幅的句子裡（DESIGN.md 4.1 節）。
    public var userFacingDescription: String {
        // 暫時照目前 App 的做法（字串內插），測試會指出問題；實作時改掉
        "\(self)"
    }
}
