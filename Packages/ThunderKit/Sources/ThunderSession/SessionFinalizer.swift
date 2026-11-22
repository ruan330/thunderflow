import Foundation
import ThunderAudio
import ThunderCore

/// 結束處理的步驟（DESIGN.md 5.7 節），依執行的順序。名稱就是記在 `session.json` 的 `completedSteps` 裡的字串。
public enum FinalizationStep: String, CaseIterable, Sendable {
    /// 基本段落：從日誌產生 `blocks.jsonl`。
    case blocks
    /// 基本逐字稿：`transcript.md`。
    case transcript
    /// 合併錄音：`recording.m4a`，確認時長一致後刪除 CAF 分段。
    case audio
    /// 發布：把資料夾從工作目錄搬進 Library。
    case publish
    /// 摘要：`summary.md`；沒有命名的場次用摘要的標題自動命名。需要網路。
    case summary
}

public struct FinalizationOptions: Sendable {
    /// Library 的位置（存放所有場次資料夾的使用者資料夾）。不存在時會自動建立。
    public var libraryRoot: URL
    /// 產生摘要用的文字模型。nil 時略過摘要（不算失敗）。
    public var textModel: (any TextModel)?
    /// 摘要用的模型 ID。
    public var summaryModel: String
    /// 是否自動產生摘要。false 時略過摘要（不算失敗）。
    public var summarize: Bool
    /// 產生摘要時最多等文字模型多久；超過就算摘要失敗（可以重試），不會讓場次一直停在處理中。
    public var summaryTimeout: Duration

    public init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
        textModel = nil
        summaryModel = "gpt-6-luna"
        summarize = true
        summaryTimeout = .seconds(300)
    }
}

public enum SessionFinalizerError: Error, Equatable {
    /// 這一場還在錄音，或上次沒有正常結束、還沒復原：先呼叫 `RecordingSession.finish()` 或 `SessionRecovery.recover`。
    case stillRecording
    /// 合併出來的 `recording.m4a` 和 CAF 分段的總長不一致（秒）。CAF 分段原封不動，沒有留下 m4a。
    case durationMismatch(recorded: TimeInterval, merged: TimeInterval)
    /// 沒有設定文字模型，不能產生摘要。
    case missingTextModel
    /// 逐字稿沒有任何文字，沒有東西可以摘要。
    case emptyTranscript
    /// 文字模型超過時限沒有回完。
    case summaryTimedOut
    /// 文字模型回傳的摘要沒有內容（沒有一句話總結、重點與章節）。
    case emptySummary
    /// 別人正在處理這一場（還在錄音，或另一個結束處理正在進行），這一次什麼都沒有做。
    case inProgress
}

extension SessionFinalizerError: CustomStringConvertible, LocalizedError {
    /// 給人看的說明（放進橫幅的句子裡，句尾不加句號）。
    public var description: String {
        switch self {
        case .stillRecording: "這一場還在錄音，或上次沒有正常結束、還沒復原"
        case .durationMismatch(let recorded, let merged):
            "合併出來的錄音（\(String(format: "%.1f", merged)) 秒）和錄下的長度（\(String(format: "%.1f", recorded)) 秒）不一致，"
                + "原本的錄音分段都還在"
        case .missingTextModel: "還沒有設定 API Key（請到「設定」貼上）"
        case .emptyTranscript: "逐字稿沒有任何文字，沒有內容可以摘要"
        case .summaryTimedOut: "文字模型超過時限沒有回完"
        case .emptySummary: "文字模型回傳的摘要沒有內容"
        case .inProgress: "這一場正在處理中"
        }
    }

    public var errorDescription: String? { description }
}

/// 結束處理：把剛錄完的場次做成成品（段落、逐字稿、錄音檔），搬進 Library，再產生摘要。
///
/// - 每一步做完就記進 `session.json` 的 `completedSteps`，所以可以中斷後接著做：再呼叫一次 `finalize`，
///   只會做還沒完成的步驟。
/// - 每一步重做的結果都一樣（不變條件 4）：同樣的日誌產生同樣的 `blocks.jsonl` 與 `transcript.md`；
///   錄音已經合併好就不再動它；已經在 Library 裡就不再搬。
/// - 前四步失敗會丟出錯誤，已經完成的成品不受影響，之後可以再呼叫一次。
/// - 摘要失敗（沒有網路、文字模型回錯誤或逾時、回傳的內容不能用）不會丟出錯誤：場次照樣完成，
///   只把 `summary` 記進 `failedSteps`，之後可以用 `regenerateSummary` 或再呼叫一次 `finalize` 重試。
/// - 每一步只在記錄的那一瞬間重新讀取並改寫 `session.json`，所以處理途中別人對它的修改（例如使用者改了標題）
///   不會被蓋掉。
/// - 會等磁碟、會占 CPU 的工作（合併錄音每小時錄音要好幾秒）在低優先權的背景佇列執行，
///   不占住 Swift concurrency 的執行緒，不影響進行中的下一場錄音與字幕。不同的場次可以同時處理。
public struct SessionFinalizer: Sendable {
    private let options: FinalizationOptions

    public init(options: FinalizationOptions) {
        self.options = options
    }

    /// 依序執行還沒記在 `completedSteps` 裡的步驟，回傳場次資料夾最後的位置（在 Library 裡）。
    ///
    /// - 每處理完一步（做完，或摘要被略過、失敗）：先把結果原子寫入 `session.json`，再呼叫 `onProgress`，
    ///   帶入這一步與場次資料夾**當下**的位置（發布、自動命名之後資料夾會換位置）。已經完成的步驟不會再回報。
    /// - 摘要：`summarize` 是 false、沒有文字模型、或逐字稿沒有任何文字時略過（不算完成也不算失敗，
    ///   下次呼叫會再看一次）；失敗時記進 `failedSteps`。兩種情況場次都照樣完成。
    /// - 這一次要處理的最後一步記錄時，狀態同時改為 `complete`；在那之前（包含發布之後）都是 `finalizing`。
    /// - 狀態還是 `recording` 的場次（還在錄音，或中斷了還沒復原）丟出 `SessionFinalizerError.stillRecording`，什麼都不動。
    /// - 呼叫端的工作被取消時，做完目前這一步就停下來（丟出 `CancellationError`），之後可以再呼叫接著做。
    /// - 處理期間持有場次的鎖（`SessionLock`），所以同一個場次同時只會有一個結束處理：
    ///   另一個結束處理（可能在另一個程式裡）正在處理時丟出 `SessionFinalizerError.inProgress`，什麼都不動。
    @discardableResult
    public func finalize(
        _ directory: SessionDirectory,
        onProgress: (@Sendable (FinalizationStep, SessionDirectory) -> Void)? = nil
    ) async throws -> SessionDirectory {
        var lock = try Self.lock(directory)
        defer { lock.release() }
        let meta = try directory.loadMeta()
        guard meta.state != .recording else { throw SessionFinalizerError.stillRecording }
        let libraryRoot = options.libraryRoot
        var directory = directory
        let pending = FinalizationStep.allCases.filter { !meta.completedSteps.contains($0.rawValue) }
        for (index, step) in pending.enumerated() {
            try Task.checkCancellation()
            let isLast = index == pending.count - 1
            let current = directory
            switch step {
            case .blocks:
                try await Self.inBackground { try Self.buildBlocks(in: current, isLast: isLast) }
            case .transcript:
                try await Self.inBackground {
                    try Self.writeTranscript(in: current)
                    try Self.update(current) { Self.complete(.transcript, in: &$0, isLast: isLast) }
                }
            case .audio:
                try await Self.inBackground { try Self.mergeAudio(in: current, isLast: isLast) }
            case .publish:
                directory = try await Self.inBackground { try Self.publish(current, into: libraryRoot, isLast: isLast) }
            case .summary:
                directory = try await summaryStep(in: current, isLast: isLast)
            }
            if directory != current { lock = Self.relock(lock, at: directory) }
            onProgress?(step, directory)
        }
        if pending.isEmpty, meta.state != .complete {
            let current = directory
            try await Self.inBackground { try Self.update(current) { $0.state = .complete } }
        }
        return directory
    }

    /// 重新產生摘要：覆寫 `summary.md` 與 `.thunderflow/summary.json`，更新 `session.json` 的一句話總結，
    /// 把摘要記成已完成並清掉「摘要失敗」。回傳場次資料夾的位置。
    ///
    /// - 和結束處理的摘要步驟做同樣的事，所以還沒有標題的場次會用摘要的標題命名，資料夾跟著改名：
    ///   這時回傳的是新的位置。已經有標題的場次不會改名，位置不變。
    /// - 不看 `summarize`（這是使用者明確要求的）。沒有文字模型丟出 `missingTextModel`，
    ///   逐字稿沒有文字丟出 `emptyTranscript`。
    /// - 失敗時丟出錯誤，原有的摘要與 `session.json` 都不動。
    /// - 結束處理正在處理這一場時丟出 `SessionFinalizerError.inProgress`，什麼都不動。
    @discardableResult
    public func regenerateSummary(_ directory: SessionDirectory) async throws -> SessionDirectory {
        guard let model = options.textModel else { throw SessionFinalizerError.missingTextModel }
        let lock = try Self.lock(directory)
        defer { lock.release() }
        return try await writeSummary(in: directory, model: model, isLast: false)
    }

    // MARK: 場次的鎖

    /// 拿到這一場的鎖。別人正持有時：還在錄音丟出 `stillRecording`，其餘丟出 `inProgress`。
    private static func lock(_ directory: SessionDirectory) throws -> SessionLock {
        if let lock = try SessionLock.acquire(directory) { return lock }
        let state = try? directory.loadMeta().state
        throw state == .recording ? SessionFinalizerError.stillRecording : SessionFinalizerError.inProgress
    }

    /// 資料夾換了位置之後確認還鎖著。同一個磁碟上的搬移，鎖本來就跟著走（這時在新的位置拿不到鎖，沿用原本的）；
    /// 搬到別的磁碟是複製後刪除，原本的鎖留在已經刪除的資料夾上，要在新的位置重新鎖。
    private static func relock(_ lock: SessionLock, at directory: SessionDirectory) -> SessionLock {
        guard let moved = try? SessionLock.acquire(directory) else { return lock }
        lock.release()
        return moved
    }

    // MARK: 步驟

    /// 步驟 2：日誌 → `blocks.jsonl`，並記下沒翻到的段數。
    private static func buildBlocks(in directory: SessionDirectory, isLast: Bool) throws {
        // 日誌不見了（資料夾被動過）也不擋住後面的步驟：當成沒有字幕，錄音照樣要處理完
        let entries =
            FileManager.default.fileExists(atPath: directory.journalURL.path)
            ? try JournalReader.read(directory.journalURL).entries : []
        let result = TranscriptBlocks.build(from: entries)
        try TranscriptBlocks.write(result.blocks, to: directory.blocksURL)
        try update(directory) { meta in
            meta.integrity.untranslatedSegments = result.untranslatedSegments
            complete(.blocks, in: &meta, isLast: isLast)
        }
    }

    /// 步驟 3：`blocks.jsonl` → `transcript.md`。
    private static func writeTranscript(in directory: SessionDirectory) throws {
        let blocks = try TranscriptBlocks.read(directory.blocksURL)
        let markdown = TranscriptMarkdown.render(meta: try directory.loadMeta(), blocks: blocks)
        try directory.writeText(markdown, to: directory.transcriptURL)
    }

    /// 合併出來的時長和 CAF 分段的總長相差在這個範圍內（秒）才算一致。
    private static let durationTolerance = 0.2

    /// 步驟 4：CAF 分段 → `recording.m4a`；確認時長一致之後才刪除 CAF 分段（包括打不開的）與空的 `audio/`。
    ///
    /// 重做時不會把已經合併好的錄音換成比較短的：`recording.m4a` 已經存在、而且不比還在的 CAF 分段短，
    /// 代表上次已經合併並確認過（中斷在刪除 CAF 的前後），這時只把剩下的 CAF 刪掉。
    /// 完全沒有聲音的場次不會產生檔案。`session.json` 的錄音長度是 0 時（復原的場次）順便補上。
    private static func mergeAudio(in directory: SessionDirectory, isLast: Bool) throws {
        let fileManager = FileManager.default
        let target = directory.recordingURL
        let segments = try RecordingFiles.segments(in: directory.audioDirectoryURL)
        let audible = segments.filter { $0.frameCount > 0 }
        let existing = fileManager.fileExists(atPath: target.path) ? (try? RecordingMerger.duration(of: target)) : nil
        var duration = existing
        if !audible.isEmpty {
            let recorded = RecordingFiles.totalDuration(of: audible)
            if let existing, existing >= recorded - durationTolerance {
                duration = existing > recorded + durationTolerance ? existing : recorded
            } else {
                let merged = try RecordingMerger.merge(segments: audible, to: target)
                guard abs(merged - recorded) <= durationTolerance else {
                    try? fileManager.removeItem(at: target)
                    throw SessionFinalizerError.durationMismatch(recorded: recorded, merged: merged)
                }
                duration = recorded
            }
        }
        // 到這裡錄音已經完整地在 recording.m4a 裡（或根本沒有聲音）：CAF 分段可以刪了。
        // 打不開的分段檔（磁碟滿了留下的空檔）裡沒有聲音，合併時略過了，這裡也一起刪，否則 audio/ 刪不掉
        for url in try RecordingFiles.segmentFiles(in: directory.audioDirectoryURL) { try fileManager.removeItem(at: url) }
        rmdir(directory.audioDirectoryURL.path)  // 空的才刪得掉

        if let duration, duration > 0, try directory.loadMeta().durationSeconds == 0 {
            try update(directory) { $0.durationSeconds = duration }
            // 逐字稿的資訊列有錄音長度，跟著更新
            if fileManager.fileExists(atPath: directory.transcriptURL.path) { try writeTranscript(in: directory) }
        }
        try update(directory) { complete(.audio, in: &$0, isLast: isLast) }
    }

    /// 步驟 5：把資料夾搬進 Library。已經在 Library 裡（任何一層）就不動。回傳資料夾現在的位置。
    private static func publish(_ directory: SessionDirectory, into libraryRoot: URL, isLast: Bool) throws -> SessionDirectory {
        var published = directory
        if !SessionLibrary.contains(directory.url, in: libraryRoot) {
            let meta = try directory.loadMeta()
            try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            published = SessionDirectory(
                url: try SessionLibrary.move(
                    directory.url, into: libraryRoot, named: SessionLibrary.folderName(for: meta),
                    stagingName: ".publishing-\(meta.id.uuidString)"))
        }
        // 先搬再記錄：就算剛搬完就被中斷，重做時會發現已經在 Library 裡，只補上記錄
        try update(published) { complete(.publish, in: &$0, isLast: isLast) }
        return published
    }

    // MARK: 摘要

    /// 步驟 7：摘要。略過或失敗都不丟出錯誤（只有工作被取消例外：那時不記成失敗，下次接著做）。
    private func summaryStep(in directory: SessionDirectory, isLast: Bool) async throws -> SessionDirectory {
        var failed = false
        if options.summarize, let model = options.textModel {
            let blocks = try? await Self.inBackground { try TranscriptBlocks.read(directory.blocksURL) }
            // 讀得到段落、而且一個字都沒有：沒有東西可以摘要，略過。讀不到段落時照常進行，由下面記成失敗
            if blocks?.contains(where: { !$0.en.isEmpty }) != false {
                do {
                    return try await writeSummary(in: directory, model: model, isLast: isLast)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    failed = true
                }
            }
        }
        let summaryFailed = failed
        try await Self.inBackground {
            try Self.update(directory) { meta in
                let name = FinalizationStep.summary.rawValue
                if summaryFailed, !meta.failedSteps.contains(name) { meta.failedSteps.append(name) }
                if isLast { meta.state = .complete }
            }
        }
        return directory
    }

    /// 向文字模型要摘要並存檔。任何一步失敗都丟出錯誤，這時 `session.json` 沒有被改動。
    private func writeSummary(
        in directory: SessionDirectory, model: any TextModel, isLast: Bool
    ) async throws -> SessionDirectory {
        let (meta, blocks) = try await Self.inBackground {
            (try directory.loadMeta(), try TranscriptBlocks.read(directory.blocksURL))
        }
        guard blocks.contains(where: { !$0.en.isEmpty }) else { throw SessionFinalizerError.emptyTranscript }
        let request = SummaryRequest.make(model: options.summaryModel, meta: meta, blocks: blocks)
        let output = try await Self.withTimeout(options.summaryTimeout) { try await model.complete(request) }
        try Task.checkCancellation()
        let summary = try SessionSummary.parse(output).keepingChapters(within: meta.durationSeconds)
        guard !summary.isEmpty else { throw SessionFinalizerError.emptySummary }
        return try await Self.inBackground { try Self.store(summary, in: directory, isLast: isLast) }
    }

    /// 寫出 `summary.json` 與 `summary.md`，沒有標題的場次順便命名，最後才把結果記進 `session.json`。
    ///
    /// 自動命名：場次還沒有標題時用摘要的標題，`transcript.md` 的標題跟著換，資料夾依新的標題改名
    /// （名稱被占用時加序號）。改名在記錄之前：就算剛改完名就被中斷，重做時標題還是空的，會整個再做一次。
    private static func store(_ summary: SessionSummary, in directory: SessionDirectory, isLast: Bool) throws -> SessionDirectory {
        var meta = try directory.loadMeta()
        let isUntitled: (SessionMeta) -> Bool = { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let naming = isUntitled(meta) && !summary.title.isEmpty
        if naming { meta.title = summary.title }

        try summary.write(to: directory.summaryDataURL)
        try directory.writeText(SummaryMarkdown.render(meta: meta, summary: summary), to: directory.summaryURL)
        var current = directory
        if naming {
            if FileManager.default.fileExists(atPath: directory.transcriptURL.path) {
                let blocks = try TranscriptBlocks.read(directory.blocksURL)
                try directory.writeText(TranscriptMarkdown.render(meta: meta, blocks: blocks), to: directory.transcriptURL)
            }
            let name = SessionLibrary.folderName(for: meta)
            if directory.url.lastPathComponent != name {
                current = SessionDirectory(
                    url: try SessionLibrary.move(
                        directory.url, into: directory.url.deletingLastPathComponent(), named: name,
                        stagingName: ".renaming-\(meta.id.uuidString)"))
            }
        }
        try update(current) { latest in
            if naming, isUntitled(latest) { latest.title = summary.title }
            latest.oneLiner = summary.oneLiner
            complete(.summary, in: &latest, isLast: isLast)
        }
        return current
    }

    /// 執行 `operation`，超過 `limit` 就取消它並丟出 `summaryTimedOut`。
    private static func withTimeout<Value: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SessionFinalizerError.summaryTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: session.json

    /// 重新讀取 `session.json`、套用變更、原子寫回。
    private static func update(_ directory: SessionDirectory, _ change: (inout SessionMeta) -> Void) throws {
        var meta = try directory.loadMeta()
        change(&meta)
        try directory.saveMeta(meta)
    }

    /// 把 `step` 記成已完成（`completedSteps` 維持步驟的順序，重做之後內容不變），並從失敗的步驟裡拿掉；
    /// 這是這一次要處理的最後一步時，狀態同時改為 `complete`。
    private static func complete(_ step: FinalizationStep, in meta: inout SessionMeta, isLast: Bool) {
        var names = meta.completedSteps
        if !names.contains(step.rawValue) { names.append(step.rawValue) }
        let known = FinalizationStep.allCases.map(\.rawValue)
        meta.completedSteps = known.filter(names.contains) + names.filter { !known.contains($0) }
        meta.failedSteps.removeAll { $0 == step.rawValue }
        if isLast { meta.state = .complete }
    }

    // MARK: 背景執行

    private static let queue = DispatchQueue(
        label: "ThunderFlow.SessionFinalizer", qos: .utility, attributes: .concurrent)

    private static func inBackground<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool { try work() } })
            }
        }
    }
}
