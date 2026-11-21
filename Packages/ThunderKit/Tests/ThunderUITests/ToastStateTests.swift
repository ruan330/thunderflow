import Testing
import ThunderUI

@Suite("提示：結果看不到的操作顯示 1.5 秒的短訊息")
struct ToastStateTests {
    @Test("還沒有提示時什麼都不顯示；提示出現後未滿 1.5 秒還在，剛好 1.5 秒與之後就消失")
    func duration() throws {
        var toasts = ToastState()
        #expect(toasts.visible(at: ms(0)) == nil)
        #expect(toasts.expiresAt == nil)

        toasts.post(.marked, "已標記重點", at: ms(0))
        let toast = try #require(toasts.visible(at: ms(0)))
        #expect(toast.kind == .marked)
        #expect(toast.text == "已標記重點")
        #expect(toasts.expiresAt == ms(1_500))
        #expect(toasts.visible(at: ms(1_499)) == toast)
        #expect(toasts.visible(at: ms(1_500)) == nil)
        #expect(toasts.visible(at: ms(1_501)) == nil)
    }

    @Test("新的提示馬上取代目前的提示，並從新的時間點重新計算 1.5 秒")
    func replaces() throws {
        var toasts = ToastState()
        toasts.post(.copied, "已複製全文", at: ms(0))
        toasts.post(.saved, "已儲存 Key", at: ms(1_000))

        let toast = try #require(toasts.visible(at: ms(1_000)))
        #expect(toast.kind == .saved)
        #expect(toast.text == "已儲存 Key")
        #expect(toasts.visible(at: ms(1_200)) == toast, "舊的那一則還沒滿 1.5 秒，但已經被取代")
        #expect(toasts.expiresAt == ms(2_500))
        #expect(toasts.visible(at: ms(2_499)) == toast)
        #expect(toasts.visible(at: ms(2_500)) == nil)
    }

    @Test("每一則提示的 id 都比前一則大；同樣的提示再出現一次也是新的一則，重新計時")
    func increasingIDs() throws {
        var toasts = ToastState()
        toasts.post(.marked, "已標記重點", at: ms(0))
        let first = try #require(toasts.visible(at: ms(0)))

        toasts.post(.marked, "已標記重點", at: ms(1_000))
        let second = try #require(toasts.visible(at: ms(1_000)))
        #expect(second.id > first.id)
        #expect(toasts.visible(at: ms(2_000))?.id == second.id, "離第一則已經 2 秒，離第二則只有 1 秒")

        toasts.post(.info, "關鍵詞從下一段起生效", at: ms(5_000))
        let third = try #require(toasts.visible(at: ms(5_000)))
        #expect(third.id > second.id)
        #expect(third.kind == .info)
    }
}
