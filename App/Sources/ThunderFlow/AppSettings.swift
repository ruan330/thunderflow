import Foundation
import Observation
import ThunderCore

/// 字幕的顯示方式。
enum DisplayMode: String, CaseIterable, Identifiable {
    case bilingual, chinese, english

    var id: String { rawValue }
    var label: String {
        switch self {
        case .bilingual: "雙語"
        case .chinese: "只看中文"
        case .english: "只看英文"
        }
    }

    /// 即時翻譯頁的分段控制用的短標籤。
    var shortLabel: String {
        switch self {
        case .bilingual: "雙語"
        case .chinese: "中文"
        case .english: "英文"
        }
    }
}

/// 一般設定，存在 UserDefaults。API Key 不在這裡，只放鑰匙圈。
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    var delay: String { didSet { defaults.set(delay, forKey: "delay") } }
    var liveTextModel: String { didSet { defaults.set(liveTextModel, forKey: "liveTextModel") } }
    var postTextModel: String { didSet { defaults.set(postTextModel, forKey: "postTextModel") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    var showsProvisional: Bool { didSet { defaults.set(showsProvisional, forKey: "showsProvisional") } }
    var autoSummary: Bool { didSet { defaults.set(autoSummary, forKey: "autoSummary") } }
    /// 每一場都會帶上的關鍵詞，一行一個。
    var keywords: String { didSet { defaults.set(keywords, forKey: "keywords") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    /// 預設的來源：`system`，或麥克風裝置的識別字串（空字串是系統預設的麥克風）。
    var sourceKey: String { didSet { defaults.set(sourceKey, forKey: "sourceKey") } }
    var libraryPath: String { didSet { defaults.set(libraryPath, forKey: "libraryPath") } }
    /// 鑰匙圈裡有沒有 Key。只是一個記號，讓畫面不用在啟動時就去讀鑰匙圈。
    var hasKey: Bool { didSet { defaults.set(hasKey, forKey: "hasKey") } }

    init() {
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? "gpt-live-transcribe"
        delay = defaults.string(forKey: "delay") ?? "low"
        liveTextModel = defaults.string(forKey: "liveTextModel") ?? "gpt-6-luna"
        postTextModel = defaults.string(forKey: "postTextModel") ?? "gpt-6-luna"
        baseURL = defaults.string(forKey: "baseURL") ?? "https://api.openai.com/v1"
        // 預設不顯示暫定譯文：字一直變比晚一點出現更干擾閱讀（HANDOVER.md P10 的實驗）
        // 暫定譯文預設開啟（D33）：整句的暫定譯文邊說邊出、幾乎只往後接，比等整句定稿好讀
        showsProvisional = defaults.object(forKey: "showsProvisional") as? Bool ?? true
        autoSummary = defaults.object(forKey: "autoSummary") as? Bool ?? true
        keywords = defaults.string(forKey: "keywords") ?? ""
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 22
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .bilingual
        sourceKey = defaults.string(forKey: "sourceKey") ?? "system"
        libraryPath =
            defaults.string(forKey: "libraryPath")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ThunderFlow").path
        hasKey = defaults.bool(forKey: "hasKey")
    }

    var libraryRoot: URL { URL(fileURLWithPath: libraryPath, isDirectory: true) }

    /// 錄音中的暫存位置。不放在「文件」裡，避免 iCloud 在錄音途中上傳暫存檔。
    /// 自動測試用啟動參數 `-workingPath <資料夾>` 換掉，和使用者自己開著的 App 分開。
    var workingRoot: URL {
        if let path = defaults.string(forKey: "workingPath"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThunderFlow/Working", isDirectory: true)
    }

    var textBaseURL: URL { URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")! }

    /// 轉錄連線的網址：和文字模型同一個主機，改用 WebSocket。
    var realtimeEndpoint: URL {
        var components = URLComponents(url: textBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/realtime"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url ?? URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// API Key 的存取。service 名稱是 Bundle ID（DESIGN.md 第 6 節）。
/// 鑰匙圈可能跳出授權視窗、等使用者回答：這三個呼叫都不要放在主執行緒上。
enum Credentials {
    static let store = KeychainStore(service: Bundle.main.bundleIdentifier ?? "io.github.ruan330.thunderflow")
    static let account = "openai-api-key"

    /// 讀出 Key 並分類：讀到、沒有、使用者沒有允許、其他錯誤。
    static func lookup() -> CredentialLookup { store.lookup(account: account) }
    static func save(_ key: String) throws { try store.save(key, account: account) }
    static func delete() throws { try store.delete(account: account) }
}

enum Format {
    /// 1:02:03 或 02:03。
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, rest) = (total / 3_600, total % 3_600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }

    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
    }

    /// 11/21 12:28。日期和時間分開格式化：合在一起時，中文的格式會把兩者黏成「11/2112:28」。
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " "
            + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}
