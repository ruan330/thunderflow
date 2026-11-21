import Foundation

public enum SessionState: String, Sendable, Codable {
    /// 錄音中。App 啟動時看到這個狀態，代表上次沒有正常結束，需要復原。
    case recording
    /// 錄音已結束，成品（錄音檔、逐字稿、摘要）處理中。
    case finalizing
    case complete
}

/// 錄音完整性：App 自己記錄這一場有沒有掉音、有多少沒翻譯到。
public struct IntegrityReport: Sendable, Equatable, Codable {
    /// RingBuffer 溢位而丟掉的樣本數。
    public var ringDroppedSamples: Int
    /// 擷取裝置回報樣本位置不連續的次數。
    public var captureDiscontinuities: Int
    /// 沒有被翻譯到的音訊長度（秒）。錄音本身不受影響。
    public var untranslatedSeconds: Double
    /// 有英文、但沒有中文定稿的段數（翻譯失敗，或還沒翻完就結束）。精修中文時會補上。
    public var untranslatedSegments: Int
    /// 錄音檔寫不進去（例如磁碟滿了）而沒有錄到的長度（秒）。這段聲音也沒有送去轉錄，所以字幕的時間仍然對得上錄音。
    public var unrecordedSeconds: Double

    public init(
        ringDroppedSamples: Int = 0,
        captureDiscontinuities: Int = 0,
        untranslatedSeconds: Double = 0,
        untranslatedSegments: Int = 0,
        unrecordedSeconds: Double = 0
    ) {
        self.ringDroppedSamples = ringDroppedSamples
        self.captureDiscontinuities = captureDiscontinuities
        self.untranslatedSeconds = untranslatedSeconds
        self.untranslatedSegments = untranslatedSegments
        self.unrecordedSeconds = unrecordedSeconds
    }

    /// 錄音有沒有完整保存下來。
    public var isRecordingComplete: Bool { ringDroppedSamples == 0 && captureDiscontinuities == 0 }

    private enum CodingKeys: String, CodingKey {
        case ringDroppedSamples, captureDiscontinuities, untranslatedSeconds, untranslatedSegments, unrecordedSeconds
    }

    /// 缺少的欄位用預設值（0），不認識的欄位忽略。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ringDroppedSamples: try container.decodeIfPresent(Int.self, forKey: .ringDroppedSamples) ?? 0,
            captureDiscontinuities: try container.decodeIfPresent(Int.self, forKey: .captureDiscontinuities) ?? 0,
            untranslatedSeconds: try container.decodeIfPresent(Double.self, forKey: .untranslatedSeconds) ?? 0,
            untranslatedSegments: try container.decodeIfPresent(Int.self, forKey: .untranslatedSegments) ?? 0,
            unrecordedSeconds: try container.decodeIfPresent(Double.self, forKey: .unrecordedSeconds) ?? 0)
    }
}

/// 一場錄音的基本資料，存成 `.thunderflow/session.json`。
///
/// 清單頁只讀這個小檔，所以放在這裡的欄位要少而精。
/// 日期存成 ISO 8601 字串（精確到秒），`id` 存成 UUID 字串。
///
/// 讀檔（`init(from:)`）時：先檢查 `schemaVersion`，比這一版新就丟出
/// `SessionStoreError.unsupportedSchemaVersion`，不再往下讀；
/// 必要欄位是 `schemaVersion`、`id`、`startedAt`、`state`，其餘缺少時用預設值，不認識的欄位忽略。
/// 日期的格式由編碼器的日期策略決定，`SessionDirectory` 使用 ISO 8601。
public struct SessionMeta: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var state: SessionState
    /// 這一場是不是從異常結束中復原的。
    public var recovered: Bool
    /// 音訊來源的說明，例如「系統音訊」「MacBook Pro 麥克風」。
    public var source: String
    /// 使用的引擎，例如「gpt-realtime-translate」。
    public var engine: String
    /// 錄音長度（音訊時間，秒）。
    public var durationSeconds: Double
    /// 引擎回報的累計計費音訊秒數。
    public var billedAudioSeconds: Double
    public var integrity: IntegrityReport
    /// 活動名稱（選填），例如「AWS re:Invent 2026」。
    public var event: String
    /// 講者（選填）。
    public var speaker: String
    /// 這一場提供給轉錄模型與翻譯模型的關鍵詞（人名、產品名稱、術語）。
    public var keywords: [String]
    /// 結束處理已經完成的步驟（`FinalizationStep` 的名稱）。中斷後重啟時，從還沒完成的步驟接著做。
    public var completedSteps: [String]
    /// 結束處理失敗、可以重試的步驟（例如沒有網路時的精修與摘要）。場次仍然算完成。
    public var failedSteps: [String]
    /// 摘要的一句話總結，給清單頁顯示。還沒有摘要時是空字串。
    public var oneLiner: String

    public init(
        id: UUID = UUID(),
        title: String = "",
        startedAt: Date,
        state: SessionState = .recording,
        recovered: Bool = false,
        source: String = "",
        engine: String = "",
        durationSeconds: Double = 0,
        billedAudioSeconds: Double = 0,
        integrity: IntegrityReport = IntegrityReport(),
        event: String = "",
        speaker: String = "",
        keywords: [String] = [],
        completedSteps: [String] = [],
        failedSteps: [String] = [],
        oneLiner: String = ""
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.state = state
        self.recovered = recovered
        self.source = source
        self.engine = engine
        self.durationSeconds = durationSeconds
        self.billedAudioSeconds = billedAudioSeconds
        self.integrity = integrity
        self.event = event
        self.speaker = speaker
        self.keywords = keywords
        self.completedSteps = completedSteps
        self.failedSteps = failedSteps
        self.oneLiner = oneLiner
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, startedAt, state, recovered, source, engine
        case durationSeconds, billedAudioSeconds, integrity
        case event, speaker, keywords, completedSteps, failedSteps, oneLiner
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 先看版本：比這一版新的檔案，其他欄位的意義可能已經不同，不能硬讀
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= Self.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchemaVersion(found: version, supported: Self.currentSchemaVersion)
        }
        // 讀進來的資料一律以這一版的格式表示，所以 schemaVersion 是目前的版本（由 init 設定）
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            state: try container.decode(SessionState.self, forKey: .state),
            recovered: try container.decodeIfPresent(Bool.self, forKey: .recovered) ?? false,
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "",
            engine: try container.decodeIfPresent(String.self, forKey: .engine) ?? "",
            durationSeconds: try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0,
            billedAudioSeconds: try container.decodeIfPresent(Double.self, forKey: .billedAudioSeconds) ?? 0,
            integrity: try container.decodeIfPresent(IntegrityReport.self, forKey: .integrity) ?? IntegrityReport(),
            event: try container.decodeIfPresent(String.self, forKey: .event) ?? "",
            speaker: try container.decodeIfPresent(String.self, forKey: .speaker) ?? "",
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords) ?? [],
            completedSteps: try container.decodeIfPresent([String].self, forKey: .completedSteps) ?? [],
            failedSteps: try container.decodeIfPresent([String].self, forKey: .failedSteps) ?? [],
            oneLiner: try container.decodeIfPresent(String.self, forKey: .oneLiner) ?? "")
    }
}
