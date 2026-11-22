import ThunderCore
import ThunderSession

/// 一個狀態的表示：符號、色調與文字。
///
/// 每個狀態都有自己的符號與文字，不只靠顏色分辨：看不出顏色差別的人、灰階的畫面上也分得出來。
/// 色調只是輔助。色調畫成什麼顏色、符號畫成哪個圖示，由 App 決定。
public struct Indicator: Sendable, Hashable {
    public var symbol: IndicatorSymbol
    public var tone: IndicatorTone
    public var text: String

    public init(symbol: IndicatorSymbol, tone: IndicatorTone, text: String) {
        self.symbol = symbol
        self.tone = tone
        self.text = text
    }
}

/// 狀態旁邊的符號。
public enum IndicatorSymbol: Sendable, Hashable, CaseIterable {
    /// 實心圓點：尚未開始、錄音中。
    case dot
    /// 暫停。
    case pause
    /// 轉圈：準備中、收尾中、處理中。
    case spinner
    /// 閃電：翻譯即時。
    case bolt
    /// 空心的閃電：翻譯還沒接上（連線中、重新連線中、待命）。
    case boltOutline
    /// 劃掉的閃電：翻譯已停止。
    case boltSlash
    /// 警告：有處理步驟失敗。
    case warning
    /// 復原：從異常結束中救回來的場次。
    case recovered
    /// 旗子：標記重點。
    case flag
}

/// 狀態的色調。
public enum IndicatorTone: Sendable, Hashable, CaseIterable {
    /// 一般，不需要特別注意。
    case neutral
    /// 翻譯即時。
    case live
    /// 錄音中。
    case recording
    /// 要留意，但不用處理：暫停、翻譯連線中、已復原。
    case attention
    /// 出了問題：翻譯停止、處理步驟失敗。
    case danger
    /// 標記重點。
    case mark
}

extension Indicator {
    /// 錄音的狀態。
    public static func recorder(_ phase: RecorderPhase) -> Indicator {
        switch phase {
        case .idle: Indicator(symbol: .dot, tone: .neutral, text: "尚未開始")
        case .starting: Indicator(symbol: .spinner, tone: .neutral, text: "準備中")
        case .recording: Indicator(symbol: .dot, tone: .recording, text: "錄音中")
        case .paused: Indicator(symbol: .pause, tone: .attention, text: "已暫停")
        case .stopping: Indicator(symbol: .spinner, tone: .neutral, text: "收尾中")
        }
    }

    /// 狀態列上的錄音狀態，和開始／停止的按鈕（`TransportSlots`）同時換（DESIGN.md 4.10.4）：
    /// 開始中、延遲顯示的「準備中」還沒出現時，仍顯示尚未開始。0.3 秒內就開始錄音時，直接從尚未開始變成錄音中。
    ///
    /// - Parameter preparingVisible: 延遲顯示的「準備中」是不是已經出現（`DelayedIndicator.isVisible(at:)`）。只在開始中有作用。
    public static func recorder(_ phase: RecorderPhase, preparingVisible: Bool) -> Indicator {
        phase == .starting && !preparingVisible ? recorder(.idle) : recorder(phase)
    }

    /// 翻譯的狀態（`LiveCaptionModel.engineStatus`）。和錄音分開顯示：翻譯斷線或停止時，錄音仍然持續。
    /// 引擎還沒回報任何狀態（nil）時當成連線中。
    public static func engine(_ status: EngineStatus?) -> Indicator {
        switch status {
        case nil, .connecting?: Indicator(symbol: .boltOutline, tone: .attention, text: "翻譯連線中")
        case .live?: Indicator(symbol: .bolt, tone: .live, text: "翻譯即時")
        case .reconnecting?: Indicator(symbol: .boltOutline, tone: .attention, text: "翻譯重新連線中，錄音持續中")
        case .idle?: Indicator(symbol: .boltOutline, tone: .neutral, text: "翻譯待命")
        case .failed(let reason)?: Indicator(symbol: .boltSlash, tone: .danger, text: "翻譯已停止：\(reason)（錄音持續中）")
        case .translationFailing(let reason)?:
            Indicator(symbol: .boltSlash, tone: .attention, text: "翻譯失敗：\(reason)（英文字幕與錄音持續中）")
        }
    }

    /// 過去錄音的狀態標籤。正常完成的場次不顯示標籤（nil）。
    ///
    /// 依序判斷：正在處理時顯示處理的進度（`progress`）；結束處理失敗顯示「處理失敗」；還沒處理完顯示「處理中」；
    /// 摘要失敗；其他步驟失敗；已復原。
    ///
    /// - Parameter failed: 這一場的結束處理失敗了（前幾步失敗時還留在工作目錄裡，下次開啟 App 時重試）。
    public static func sessionBadge(_ meta: SessionMeta, progress: String? = nil, failed: Bool = false) -> Indicator? {
        if let progress { return Indicator(symbol: .spinner, tone: .neutral, text: progress) }
        if failed { return Indicator(symbol: .warning, tone: .danger, text: "處理失敗") }
        if meta.state != .complete { return Indicator(symbol: .spinner, tone: .neutral, text: "處理中") }
        if meta.failedSteps.contains(FinalizationStep.summary.rawValue) {
            return Indicator(symbol: .warning, tone: .danger, text: "摘要失敗")
        }
        if !meta.failedSteps.isEmpty { return Indicator(symbol: .warning, tone: .danger, text: "部分處理失敗") }
        if meta.recovered { return Indicator(symbol: .recovered, tone: .attention, text: "已復原") }
        return nil
    }
}
