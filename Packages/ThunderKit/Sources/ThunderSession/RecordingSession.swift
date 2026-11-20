import Foundation
import ThunderAudio
import ThunderCore

public enum RecordingSessionError: Error, Equatable {
    /// 場次已經結束，不能再送入音訊。
    case alreadyFinished
}

/// 一場錄音：把音訊寫成分段錄音、轉送給引擎，並把引擎的字幕寫進日誌。
///
/// 最重要的保證：**錄音不受引擎影響**。`process` 是同步的，只做寫檔、轉格式、
/// 把音訊放進引擎的等待區（立即返回）；引擎卡住、變慢、提早結束，都不會讓它等待或遺失樣本。
///
/// 執行緒規則：
/// - `process` 只能由一條執行緒呼叫（Pump）。
/// - `pause`、`resume`、`mark` 與各個屬性可以從任何執行緒呼叫。
public final class RecordingSession: @unchecked Sendable {
    /// 建立場次：建立資料夾、寫入 `session.json`（狀態為 recording）、開啟錄音與日誌。
    public init(config: SessionConfig, directory: SessionDirectory, engine: any LiveCaptionEngine) throws {
        throw NotYetImplemented("RecordingSession.init")
    }

    /// 目前的音訊時間：已經錄下的長度（不含暫停）。
    public var audioTime: AudioTime { .zero }

    public var isPaused: Bool { false }

    /// 引擎是否還在運作。引擎自己結束（例如回報失敗）之後會變成 false，錄音不受影響。
    public var isEngineRunning: Bool { false }

    /// 啟動引擎，開始接收字幕。
    public func start() {}

    /// 送入來源樣本（單聲道、`config.sampleRate`）。同步執行，不等待引擎。
    /// 暫停中送入的樣本會被丟棄；結束之後呼叫會丟出 `RecordingSessionError.alreadyFinished`。
    public func process(_ samples: UnsafeBufferPointer<Float>) throws {
        throw NotYetImplemented("RecordingSession.process(_:)")
    }

    /// 暫停：之後送入的樣本不錄、不送引擎，音訊時間不前進。
    public func pause() {}

    public func resume() {}

    /// 在目前的音訊時間加上一個重點標記。
    public func mark() {}

    /// 結束錄音：關閉錄音檔、送出剩下的音訊、等引擎收尾（最多 `engineDrainTimeout`），
    /// 並把 `session.json` 更新為 finalizing。重複呼叫會回傳同一份結果。
    @discardableResult
    public func finish() async throws -> SessionMeta {
        throw NotYetImplemented("RecordingSession.finish()")
    }
}
