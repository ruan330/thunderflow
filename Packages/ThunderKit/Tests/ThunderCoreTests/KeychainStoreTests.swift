import Foundation
import Testing
import ThunderCore

@Suite("鑰匙圈：憑證的存取")
struct KeychainStoreTests {
    @Test("存入、讀出、覆寫、刪除；不同的 service 與帳號互不影響")
    func roundTrip() throws {
        // 每次用一個新的 service 名稱，不會碰到使用者真正的項目；結束時刪掉
        let store = KeychainStore(service: "thunderflow.tests.\(UUID().uuidString)")
        defer {
            try? store.delete(account: "openai")
            try? store.delete(account: "other")
        }
        #expect(try store.read(account: "openai") == nil)

        try store.save("sk-test-FAKE-1", account: "openai")
        #expect(try store.read(account: "openai") == "sk-test-FAKE-1")

        try store.save("sk-test-FAKE-2", account: "openai")
        #expect(try store.read(account: "openai") == "sk-test-FAKE-2")
        #expect(try store.read(account: "other") == nil)
        #expect(try KeychainStore(service: store.service + ".x").read(account: "openai") == nil)

        try store.delete(account: "openai")
        #expect(try store.read(account: "openai") == nil)
        try store.delete(account: "openai")  // 重複刪除不算錯
    }
}
