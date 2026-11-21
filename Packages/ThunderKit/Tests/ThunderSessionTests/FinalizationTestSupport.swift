import Foundation
import Testing
import ThunderAudio
import ThunderCore
import ThunderSession
import ThunderTestKit

/// 已經結束錄音、等著做結束處理的場次（狀態是 finalizing）。不經過 `RecordingSession`，直接寫出資料夾，
/// 所以日誌的內容完全由測試決定。
enum Finished {
    /// 2026-12-02T02:30:00Z（台北時間 10:30）。
    static let startedAt = Date(timeIntervalSince1970: 1_796_178_600)
    static let title = "Building Agents with Bedrock"

    static func source(_ text: String, at time: Double, seg: Int? = nil, end: Bool = true) -> JournalEntry {
        .source(CaptionText(text: text, kind: end ? .segmentEnd : .delta, at: AudioTime(seconds: time), segment: seg))
    }

    static func translation(_ text: String, at time: Double, seg: Int? = nil) -> JournalEntry {
        .translation(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
    }

    /// 六段、兩個段落；第 4 段沒翻到；第二個段落有一個重點標記。
    static let journal: [JournalEntry] = [
        source("Welcome everyone.", at: 10, seg: 0), translation("歡迎各位。", at: 11, seg: 0),
        source("Today we talk about agents.", at: 16, seg: 1), translation("今天我們要談 Agent。", at: 17, seg: 1),
        source("They can call tools,", at: 24, seg: 2), translation("它們可以呼叫工具，", at: 25, seg: 2),
        source("and remember things.", at: 31, seg: 3), translation("也能記住事情。", at: 32, seg: 3),
        source("Let's look at a demo.", at: 36, seg: 4),
        .marker(at: AudioTime(seconds: 38)),
        source("First, open the console.", at: 41, seg: 5), translation("首先，打開主控台。", at: 42, seg: 5),
    ]

    /// `journal` 應該產生的段落。
    static let blocks = [
        TranscriptBlock(
            id: 0, start: 8, en: "Welcome everyone. Today we talk about agents. They can call tools, and remember things.",
            zh: "歡迎各位。今天我們要談 Agent。它們可以呼叫工具，也能記住事情。", segments: [0, 1, 2, 3], marked: false),
        TranscriptBlock(
            id: 1, start: 34, en: "Let's look at a demo. First, open the console.", zh: "首先，打開主控台。",
            segments: [4, 5], marked: true),
    ]

    /// 在 `workingRoot` 底下建立一個場次資料夾（以場次 id 命名）：`session.json`、日誌，以及 `audio` 指定長度（秒）的 CAF 分段。
    static func makeSession(
        in workingRoot: URL,
        title: String = title,
        journal: [JournalEntry] = journal,
        audio: [Double] = [30, 15],
        sampleRate: Double = 8_000,
        configure: (inout SessionMeta) -> Void = { _ in }
    ) throws -> SessionDirectory {
        var meta = SessionMeta(
            title: title, startedAt: startedAt, state: .finalizing, source: "系統音訊", engine: "scripted",
            durationSeconds: audio.reduce(0, +))
        configure(&meta)
        let directory = SessionDirectory(url: workingRoot.appendingPathComponent(meta.id.uuidString, isDirectory: true))
        try directory.create()
        try directory.saveMeta(meta)
        let writer = try JournalWriter(url: directory.journalURL)
        for entry in journal { try writer.append(entry) }
        writer.close()

        guard !audio.isEmpty else { return directory }
        let recorder = try SegmentedRecorder(
            directory: directory.audioDirectoryURL, sampleRate: sampleRate, segmentDuration: 3_600)
        let oneSecond = Signal.sine(frequency: 220, sampleRate: sampleRate, duration: 1)
        for (index, seconds) in audio.enumerated() {
            if index > 0 { try recorder.beginNewSegment() }
            var remaining = Int((seconds * sampleRate).rounded())
            while remaining > 0 {
                let count = min(remaining, oneSecond.count)
                try oneSecond[..<count].withUnsafeBufferPointer { try recorder.append($0) }
                remaining -= count
            }
        }
        try recorder.close()
        return directory
    }

    /// 標準的場次（`makeSession` 的預設值）做完結束處理、沒有摘要時應該有的樣子。
    static func expectPublished(_ published: SessionDirectory, in library: URL) throws {
        let meta = try published.loadMeta()
        #expect(published.url.deletingLastPathComponent().path == library.path)
        #expect(published.url.lastPathComponent == SessionLibrary.folderName(for: meta))
        #expect(meta.state == .complete)
        #expect(meta.completedSteps == ["blocks", "transcript", "audio", "publish"])
        #expect(meta.failedSteps.isEmpty)
        #expect(meta.integrity.untranslatedSegments == 1)
        #expect(meta.durationSeconds == 45)
        #expect(try TranscriptBlocks.read(published.blocksURL) == blocks)
        #expect(
            try String(contentsOf: published.transcriptURL, encoding: .utf8)
                == TranscriptMarkdown.render(meta: meta, blocks: blocks))
        #expect(abs(try RecordingMerger.duration(of: published.recordingURL) - 45) < 0.2)
        #expect(try JournalReader.read(published.journalURL).entries == journal)
        #expect(
            filePaths(in: published.url) == [
                ".thunderflow/blocks.jsonl", ".thunderflow/journal.jsonl", ".thunderflow/session.json", "recording.m4a",
                "transcript.md",
            ])
    }
}

/// 記下 `onProgress` 每一次回報的步驟、位置，以及當下 `session.json` 的內容。
final class ProgressLog: Sendable {
    struct Entry: Sendable, Equatable {
        var step: FinalizationStep
        var directory: SessionDirectory
        var completedSteps: [String]
        var state: SessionState?
    }

    private let entries = LockedValue<[Entry]>([])

    var all: [Entry] { entries.value }
    var steps: [FinalizationStep] { all.map(\.step) }

    func record(_ step: FinalizationStep, _ directory: SessionDirectory) {
        let meta = try? directory.loadMeta()
        entries.withValue {
            $0.append(
                Entry(step: step, directory: directory, completedSteps: meta?.completedSteps ?? [], state: meta?.state))
        }
    }
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// 資料夾裡所有檔案的相對路徑（含隱藏檔，不含資料夾本身），依字母排序。
func filePaths(in folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    var paths: [String] = []
    for case let path as String in enumerator {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            paths.append(path)
        }
    }
    return paths.sorted()
}

/// 資料夾裡每個檔案的內容，用來確認「重做之後一模一樣」。
func folderSnapshot(_ folder: URL) throws -> [String: Data] {
    var snapshot: [String: Data] = [:]
    for path in filePaths(in: folder) {
        snapshot[path] = try Data(contentsOf: folder.appendingPathComponent(path))
    }
    return snapshot
}
