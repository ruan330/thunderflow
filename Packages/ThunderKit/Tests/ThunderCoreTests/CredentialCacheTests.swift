import Foundation
import Security
import Testing
import ThunderCore

/// 讀過一次的 API Key 留在記憶體裡，按下開始時不用每次都讀鑰匙圈。不碰真正的鑰匙圈。
@Suite("API Key 留在記憶體：讀過一次就不再讀鑰匙圈")
struct CredentialCacheTests {
    @Test("還沒讀過時沒有 Key；讀到之後記住，下次按開始直接用")
    func remembersAFoundKey() {
        var cache = CredentialCache()
        #expect(cache.key == nil)

        cache.remember(.found("sk-test-FAKE"), ticket: cache.ticket)

        #expect(cache.key == "sk-test-FAKE")
    }

    @Test(
        "沒有 Key、鑰匙圈沒有允許或其他錯誤：什麼都不記，下次按開始再讀一次",
        arguments: [CredentialLookup.missing, .denied, .failed(KeychainError(status: errSecParam))])
    func remembersOnlyAFoundKey(lookup: CredentialLookup) {
        var cache = CredentialCache()

        cache.remember(lookup, ticket: cache.ticket)

        #expect(cache.key == nil)
    }

    @Test("設定頁存入或刪除 Key 之後忘掉記住的值，下次按開始重新讀鑰匙圈")
    func invalidateForgetsTheKey() {
        var cache = CredentialCache()
        cache.remember(.found("sk-test-FAKE-old"), ticket: cache.ticket)

        cache.invalidate()

        #expect(cache.key == nil)
    }

    @Test("讀鑰匙圈的途中 Key 被存入或刪除：那次讀到的舊值不記住；之後重新讀到的照常記住")
    func aReadThatStartedBeforeAChangeIsNotRemembered() {
        var cache = CredentialCache()
        let ticket = cache.ticket  // 開始讀鑰匙圈
        cache.invalidate()  // 讀的途中，設定頁存入了新的 Key

        cache.remember(.found("sk-test-FAKE-old"), ticket: ticket)
        #expect(cache.key == nil)

        cache.remember(.found("sk-test-FAKE-new"), ticket: cache.ticket)
        #expect(cache.key == "sk-test-FAKE-new")
    }

    @Test("記住的 Key 印出來（例如寫進 log）不會帶出 Key 本身")
    func descriptionHidesTheKey() {
        var cache = CredentialCache()
        cache.remember(.found("sk-test-FAKE-secret"), ticket: cache.ticket)

        #expect(!String(describing: cache).contains("sk-test-FAKE-secret"))
        #expect(!String(reflecting: cache).contains("sk-test-FAKE-secret"))
    }
}
