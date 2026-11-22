import Foundation
import Security
import Testing
import ThunderCore

/// 鑰匙圈的結果怎麼分類（DESIGN.md 第 6 節）。只用狀態碼與假的讀取，不碰真正的鑰匙圈。
@Suite("鑰匙圈：讀取的結果與錯誤的分類")
struct CredentialLookupTests {
    @Test(
        "狀態碼分成四類：成功、沒有這個項目、使用者拒絕或取消（或不能跳出授權視窗）、其他錯誤",
        arguments: [
            (errSecSuccess, KeychainOutcome.success),
            (errSecItemNotFound, .notFound),
            (errSecAuthFailed, .denied),
            (errSecUserCanceled, .denied),
            (errSecInteractionNotAllowed, .denied),
            (errSecMissingEntitlement, .failed(errSecMissingEntitlement)),
            (errSecDuplicateItem, .failed(errSecDuplicateItem)),
            (errSecParam, .failed(errSecParam)),
        ] as [(OSStatus, KeychainOutcome)])
    func classifiesStatus(status: OSStatus, expected: KeychainOutcome) {
        #expect(KeychainOutcome(status: status) == expected)
        #expect(KeychainError(status: status).outcome == expected)
    }

    @Test("讀到 Key：算成找到")
    func found() {
        #expect(CredentialLookup { "sk-test-FAKE" } == .found("sk-test-FAKE"))
    }

    @Test("鑰匙圈裡沒有，或存的是空字串：算成沒有 Key")
    func missing() {
        #expect(CredentialLookup { nil } == .missing)
        #expect(CredentialLookup { "" } == .missing)
        #expect(CredentialLookup { throw KeychainError(status: errSecItemNotFound) } == .missing)
    }

    @Test(
        "使用者在授權視窗按了拒絕或取消、或現在不能跳出視窗：算成沒有允許，不是沒有 Key",
        arguments: [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed])
    func denied(status: OSStatus) {
        #expect(CredentialLookup { throw KeychainError(status: status) } == .denied)
    }

    @Test("其他錯誤：保留原本的錯誤與狀態碼，畫面照實說明")
    func otherErrors() {
        let error = KeychainError(status: errSecMissingEntitlement)
        #expect(CredentialLookup { throw error } == .failed(error))
    }

    @Test("讀取的結果印出來（例如寫進 log）不會帶出 Key 本身")
    func descriptionHidesTheKey() {
        let lookup = CredentialLookup.found("sk-test-FAKE-secret")
        #expect(!String(describing: lookup).contains("sk-test-FAKE-secret"))
        #expect(!String(reflecting: lookup).contains("sk-test-FAKE-secret"))
        #expect(!"\(lookup)".contains("sk-test-FAKE-secret"))
    }
}
