import Testing
import ThunderAudio

/// 選哪一個麥克風（DESIGN.md 5.4 節）：記住的裝置不在了，就改用系統預設的輸入裝置照樣開始錄音，並說明用了哪一個。
/// 只用假的裝置清單，不碰 Core Audio。
@Suite("麥克風：開始時選用的裝置")
struct MicrophoneChoiceTests {
    private let builtIn = AudioInputDevice(
        id: 71, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro 麥克風", sampleRate: 48_000, channels: 1, isDefault: true)
    private let usb = AudioInputDevice(
        id: 88, uid: "AppleUSBAudioEngine:Blue:Yeti:1234:1", name: "Yeti", sampleRate: 48_000, channels: 2, isDefault: false)
    private let iPhoneUID = "B8F2-Continuity-Microphone"

    @Test("沒有指定裝置（nil 或空字串）：用系統預設的輸入裝置，不需要說明", arguments: [nil, ""] as [String?])
    func usesTheDefaultWhenNothingIsChosen(uid: String?) throws {
        let choice = try #require(MicrophoneChoice.choose(uid: uid, from: [usb, builtIn]))
        #expect(choice.device == builtIn)
        #expect(choice.missingUID == nil)
        #expect(choice.notice == nil)
    }

    @Test("指定的裝置還在：用它，不需要說明")
    func usesTheChosenDevice() throws {
        let choice = try #require(MicrophoneChoice.choose(uid: usb.uid, from: [builtIn, usb]))
        #expect(choice.device == usb)
        #expect(choice.missingUID == nil)
        #expect(choice.notice == nil)
    }

    @Test("指定的裝置不在了（拔掉、iPhone 拿起來解鎖）：改用系統預設的輸入裝置照樣開始，說明用了哪一個，不顯示看不懂的 UID")
    func fallsBackToTheDefaultWithANotice() throws {
        let choice = try #require(MicrophoneChoice.choose(uid: iPhoneUID, from: [builtIn, usb]))
        #expect(choice.device == builtIn)
        #expect(choice.missingUID == iPhoneUID)
        let notice = try #require(choice.notice)
        #expect(notice.contains("MacBook Pro 麥克風"))
        #expect(!notice.contains(iPhoneUID))
    }

    @Test("清單裡沒有標記為預設的裝置：用第一個")
    func usesTheFirstDeviceWhenNoneIsTheDefault() {
        var builtInNotDefault = builtIn
        builtInNotDefault.isDefault = false
        #expect(MicrophoneChoice.choose(uid: nil, from: [usb, builtInNotDefault])?.device == usb)
        #expect(MicrophoneChoice.choose(uid: iPhoneUID, from: [usb, builtInNotDefault])?.device == usb)
    }

    @Test("一個可以收音的裝置都沒有：選不出來", arguments: [nil, "", "B8F2-Continuity-Microphone"] as [String?])
    func nothingToChoose(uid: String?) {
        #expect(MicrophoneChoice.choose(uid: uid, from: []) == nil)
    }
}
