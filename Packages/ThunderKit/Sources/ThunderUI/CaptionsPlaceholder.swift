/// 字幕區還沒有任何字幕時的說明（DESIGN.md 4.10.4）。
///
/// 依錄音的階段換說法：按下開始之後就不再叫使用者「按下開始錄音」。符號畫成什麼由 App 決定。
public struct CaptionsPlaceholder: Sendable, Hashable {
    public var symbol: IndicatorSymbol
    public var title: String
    public var message: String

    public init(phase: RecorderPhase) {
        switch phase {
        case .idle, .stopping:
            // 收尾中：沒有字幕的一場結束了，回到一開始的說明
            symbol = .bolt
            title = "按下「開始錄音」"
            message = "講者說英文時，這裡會即時出現英文逐字稿與台灣繁體中文翻譯。"
        case .starting, .recording:
            symbol = .bolt
            title = "正在聆聽"
            message = "講者開口之後，英文逐字稿與中文翻譯會即時出現在這裡。"
        case .paused:
            symbol = .pause
            title = "已暫停"
            message = "按「繼續」接著錄音。"
        }
    }
}
