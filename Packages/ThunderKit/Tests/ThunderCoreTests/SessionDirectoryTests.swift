import Foundation
import Testing
import ThunderCore
import ThunderTestKit

@Suite("場次資料夾：session.json 的讀寫")
struct SessionDirectoryTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_796_000_000)

    private func sampleMeta() -> SessionMeta {
        SessionMeta(
            id: UUID(uuidString: "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC")!,
            title: "Building Agents with Bedrock",
            startedAt: Self.startedAt,
            state: .finalizing,
            recovered: true,
            source: "系統音訊",
            engine: "gpt-realtime-translate",
            durationSeconds: 3_492.5,
            billedAudioSeconds: 3_480,
            integrity: IntegrityReport(ringDroppedSamples: 0, captureDiscontinuities: 1, untranslatedSeconds: 12.5))
    }

    private func makeDirectory(in tmp: TemporaryDirectory) throws -> SessionDirectory {
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("session"))
        try directory.create()
        return directory
    }

    @Test("資料夾結構：基本資料、日誌、錄音分段都放在隱藏的 .thunderflow 裡")
    func layout() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let root = directory.url.path

        #expect(directory.metaURL.path == root + "/.thunderflow/session.json")
        #expect(directory.journalURL.path == root + "/.thunderflow/journal.jsonl")
        #expect(directory.audioDirectoryURL.path == root + "/.thunderflow/audio")

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.audioDirectoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        // 重複建立不算錯
        try directory.create()
    }

    @Test("寫進去的基本資料，讀出來一模一樣")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let meta = sampleMeta()

        try directory.saveMeta(meta)

        #expect(try directory.loadMeta() == meta)
    }

    @Test("session.json 是人看得懂的 JSON：日期是 ISO 8601，id 是 UUID 字串")
    func humanReadableFormat() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)

        try directory.saveMeta(sampleMeta())

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.metaURL))
        let json = try #require(object as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["id"] as? String == "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC")
        #expect(json["title"] as? String == "Building Agents with Bedrock")
        #expect(json["startedAt"] as? String == "2026-11-30T00:53:20Z")
        #expect(json["state"] as? String == "finalizing")
        #expect(json["recovered"] as? Bool == true)
        #expect(json["source"] as? String == "系統音訊")
        #expect(json["engine"] as? String == "gpt-realtime-translate")
        #expect(json["durationSeconds"] as? Double == 3_492.5)
        #expect(json["billedAudioSeconds"] as? Double == 3_480)
        let integrity = try #require(json["integrity"] as? [String: Any])
        #expect(integrity["ringDroppedSamples"] as? Int == 0)
        #expect(integrity["captureDiscontinuities"] as? Int == 1)
        #expect(integrity["untranslatedSeconds"] as? Double == 12.5)
    }

    @Test("讀得懂只有必要欄位的檔案，其餘用預設值；不認識的欄位會忽略")
    func tolerantDecoding() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let minimal = """
            {
              "schemaVersion": 1,
              "id": "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC",
              "startedAt": "2026-11-30T00:53:20Z",
              "state": "recording",
              "addedByAFutureVersion": { "anything": [1, 2, 3] }
            }
            """
        try minimal.write(to: directory.metaURL, atomically: true, encoding: .utf8)

        let meta = try directory.loadMeta()

        #expect(meta == SessionMeta(
            id: UUID(uuidString: "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC")!,
            startedAt: Self.startedAt,
            state: .recording))
    }

    @Test("比這一版還新的格式：明確拒絕，而不是讀出錯誤的資料")
    func rejectsNewerSchema() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        let future = """
            { "schemaVersion": 99, "id": "6F1C0E0A-3B4D-4C5E-8F90-123456789ABC",
              "startedAt": "2026-11-30T00:53:20Z", "state": "recording" }
            """
        try future.write(to: directory.metaURL, atomically: true, encoding: .utf8)

        #expect(throws: SessionStoreError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try directory.loadMeta()
        }
    }

    @Test("原子寫入：反覆覆寫的同時，讀的人永遠讀到完整的檔")
    func atomicOverwrite() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)
        var meta = sampleMeta()
        try directory.saveMeta(meta)

        let stop = LockedValue(false)
        let readFailures = LockedValue(0)
        let reads = LockedValue(0)
        let reader = Thread {
            while !stop.value {
                do {
                    _ = try directory.loadMeta()
                    reads.withValue { $0 += 1 }
                } catch {
                    readFailures.withValue { $0 += 1 }
                }
            }
        }
        reader.start()
        for round in 1...300 {
            meta.durationSeconds = Double(round)
            meta.title = String(repeating: "很長的標題", count: round % 50 + 1)
            try directory.saveMeta(meta)
        }
        stop.withValue { $0 = true }
        while !reader.isFinished { usleep(1_000) }

        #expect(readFailures.value == 0)
        #expect(reads.value > 0)
        #expect(try directory.loadMeta().durationSeconds == 300)
    }

    @Test("寫入後不留下暫存檔")
    func leavesNoTemporaryFiles() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)

        for _ in 0..<5 { try directory.saveMeta(sampleMeta()) }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.hiddenDirectoryURL.path).sorted()
        #expect(names == ["audio", "session.json"])
    }

    @Test("session.json 不存在時丟出錯誤")
    func missingFileThrows() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = try makeDirectory(in: tmp)

        #expect(throws: (any Error).self) { try directory.loadMeta() }
    }

    @Test("完整性：沒有掉樣本、沒有不連續，才算錄音完整（沒翻譯到不影響錄音完整）")
    func integritySummary() {
        #expect(IntegrityReport().isRecordingComplete)
        #expect(IntegrityReport(untranslatedSeconds: 60).isRecordingComplete)
        #expect(!IntegrityReport(ringDroppedSamples: 1).isRecordingComplete)
        #expect(!IntegrityReport(captureDiscontinuities: 1).isRecordingComplete)
    }
}
