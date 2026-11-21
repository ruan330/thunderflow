import Foundation
import ThunderCore

/// 一場錄音的設定。
public struct SessionConfig: Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    /// 活動名稱與講者（選填）。和關鍵詞一起記在 `session.json`，結束後的精修與摘要會用到。
    public var event: String
    public var speaker: String
    /// 這一場的關鍵詞（人名、產品名稱、術語）。
    public var keywords: [String]
    /// 音訊來源的說明，例如「系統音訊」。
    public var source: String
    /// 來源取樣率（單聲道）。
    public var sampleRate: Double
    /// 錄音分段的長度（秒）。
    public var segmentDuration: TimeInterval

    /// 引擎的名稱，記錄在 `session.json`。
    public var engineName: String
    public var engine: EngineConfig
    /// 送給引擎的取樣率。
    public var engineSampleRate: Int
    /// 送給引擎的每包長度（秒）。
    public var engineChunkDuration: TimeInterval
    /// 等待區的上限（秒）：引擎來不及消化時，最多保留這麼長的音訊，更舊的丟掉並記成缺口。
    public var engineBufferDuration: TimeInterval
    /// 結束時最多等引擎收尾多久；超過就放棄等待。
    public var engineDrainTimeout: Duration

    public init(sampleRate: Double) {
        self.id = UUID()
        self.title = ""
        self.startedAt = Date()
        self.event = ""
        self.speaker = ""
        self.keywords = []
        self.source = ""
        self.sampleRate = sampleRate
        self.segmentDuration = 600
        self.engineName = ""
        self.engine = EngineConfig()
        self.engineSampleRate = 24_000
        self.engineChunkDuration = 0.2
        self.engineBufferDuration = 10
        self.engineDrainTimeout = .seconds(5)
    }
}
