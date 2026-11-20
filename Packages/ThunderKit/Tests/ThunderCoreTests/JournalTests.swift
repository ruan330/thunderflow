import Foundation
import Testing
import ThunderCore
import ThunderTestKit

@Suite("日誌：錄音中只追加寫入的原始紀錄")
struct JournalTests {
    private static let everyKind: [JournalEntry] = [
        .source(CaptionText(text: "Hello", kind: .delta, at: AudioTime(seconds: 12.5))),
        .source(CaptionText(text: " world.", kind: .segmentEnd, at: AudioTime(seconds: 13))),
        .translation(CaptionText(text: "哈囉，世界。", kind: .segmentEnd, at: AudioTime(seconds: 13.25))),
        .gap(AudioGap(from: AudioTime(seconds: 30), to: AudioTime(seconds: 42.5), reason: .network)),
        .gap(AudioGap(from: AudioTime(seconds: 50), to: AudioTime(seconds: 51), reason: .backpressure)),
        .gap(AudioGap(from: AudioTime(seconds: 60), to: AudioTime(seconds: 90), reason: .engineStopped)),
        .marker(at: AudioTime(seconds: 95)),
        .paused(at: AudioTime(seconds: 120)),
        .resumed(at: AudioTime(seconds: 120)),
    ]

    private func write(_ entries: [JournalEntry], to url: URL) throws {
        let writer = try JournalWriter(url: url)
        for entry in entries { try writer.append(entry) }
        writer.close()
    }

    @Test("每一種紀錄寫進去再讀出來都一樣")
    func roundTrip() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        try write(Self.everyKind, to: url)
        let contents = try JournalReader.read(url)

        #expect(contents.entries == Self.everyKind)
        #expect(!contents.hasTruncatedTail)
        #expect(contents.skippedLineCount == 0)
    }

    @Test("一筆紀錄剛好一行，文字裡有換行、引號、表情符號也一樣")
    func oneLinePerEntry() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let tricky: [JournalEntry] = [
            .source(CaptionText(text: "line one\nline two\r\n\"quoted\" \\ back\tslash", kind: .segmentEnd, at: .zero)),
            .translation(CaptionText(text: "第一行\n第二行「引號」🎉", kind: .segmentEnd, at: AudioTime(seconds: 1))),
        ]

        try write(tricky, to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == tricky.count + 1)
        #expect(try JournalReader.read(url).entries == tricky)
    }

    @Test("文件記載的 v1 格式讀得懂")
    func readsDocumentedFormat() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let lines = [
            #"{"k":"src","t":12.5,"x":"Hello","end":true}"#,
            #"{"k":"src","t":12.75,"x":" there"}"#,
            #"{"k":"tr","t":13.25,"x":"你好","end":true}"#,
            #"{"k":"gap","from":30,"to":42.5,"why":"network"}"#,
            #"{"k":"mark","t":95}"#,
            #"{"k":"pause","t":120}"#,
            #"{"k":"resume","t":120}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let contents = try JournalReader.read(url)

        #expect(contents.entries == [
            .source(CaptionText(text: "Hello", kind: .segmentEnd, at: AudioTime(seconds: 12.5))),
            .source(CaptionText(text: " there", kind: .delta, at: AudioTime(seconds: 12.75))),
            .translation(CaptionText(text: "你好", kind: .segmentEnd, at: AudioTime(seconds: 13.25))),
            .gap(AudioGap(from: AudioTime(seconds: 30), to: AudioTime(seconds: 42.5), reason: .network)),
            .marker(at: AudioTime(seconds: 95)),
            .paused(at: AudioTime(seconds: 120)),
            .resumed(at: AudioTime(seconds: 120)),
        ])
        #expect(contents.skippedLineCount == 0)
    }

    @Test("中文以 UTF-8 原文存放，斜線不加跳脫（方便直接搜尋與人工閱讀）")
    func storesTextVerbatim() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        try write([.translation(CaptionText(text: "可用區域 us-east-1a/1b", kind: .segmentEnd, at: .zero))], to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("可用區域 us-east-1a/1b"))
        #expect(!raw.contains("\\u"))
    }

    @Test("append 返回時資料已經在檔案裡，不必等關檔")
    func appendIsWriteThrough() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let writer = try JournalWriter(url: url)
        defer { writer.close() }

        try writer.append(Self.everyKind[0])
        #expect(try JournalReader.read(url).entries == [Self.everyKind[0]])

        try writer.append(Self.everyKind[2])
        #expect(try JournalReader.read(url).entries == [Self.everyKind[0], Self.everyKind[2]])
    }

    /// 寫入端每次都把「一行＋換行」一次寫出去，所以沒有以換行結尾的最後一行一律視為不完整：
    /// 就算剩下的內容剛好是合法的 JSON（例如 12.5 被切成 12），也不能相信。
    @Test("最後一行寫到一半被中斷：略過那半行，前面的紀錄都還在", arguments: [1, 5, 20])
    func toleratesTruncatedTail(bytesCutOff: Int) throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        try write(Array(Self.everyKind.prefix(3)), to: url)

        let full = try Data(contentsOf: url)
        try full.dropLast(bytesCutOff).write(to: url)
        let contents = try JournalReader.read(url)

        #expect(contents.entries == Array(Self.everyKind.prefix(2)))
        #expect(contents.hasTruncatedTail)
    }

    @Test("看不懂的行（未來版本的新種類、損壞的內容）會跳過並計數，不影響其他行")
    func skipsUnknownLines() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let lines = [
            #"{"k":"mark","t":1}"#,
            #"{"k":"speaker","t":2,"name":"future feature"}"#,
            #"this is not json"#,
            #"{"k":"mark","t":3}"#,
            #"{"k":"gap","from":4,"to":5,"why":"a reason from the future"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let contents = try JournalReader.read(url)

        #expect(contents.entries == [
            .marker(at: AudioTime(seconds: 1)),
            .marker(at: AudioTime(seconds: 3)),
            .gap(AudioGap(from: AudioTime(seconds: 4), to: AudioTime(seconds: 5), reason: .unknown)),
        ])
        #expect(contents.skippedLineCount == 2)
        #expect(!contents.hasTruncatedTail)
    }

    @Test("重新開啟既有的日誌會接在後面寫，不會蓋掉原本的內容")
    func reopeningAppends() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        try write(Array(Self.everyKind.prefix(2)), to: url)
        try write(Array(Self.everyKind.suffix(2)), to: url)

        #expect(try JournalReader.read(url).entries == Array(Self.everyKind.prefix(2) + Self.everyKind.suffix(2)))
    }

    @Test("多條執行緒同時寫入：每一行都完整，一筆不少")
    func concurrentAppendsStayIntact() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let writer = try JournalWriter(url: url)
        let threads = 8
        let perThread = 500
        let failures = LockedValue(0)

        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in 0..<perThread {
                let text = String(repeating: "字幕\(thread)-\(index) ", count: 20)
                let entry = JournalEntry.translation(
                    CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: Double(thread * 1_000 + index))))
                do { try writer.append(entry) } catch { failures.withValue { $0 += 1 } }
            }
        }
        writer.close()
        let contents = try JournalReader.read(url)

        #expect(failures.value == 0)
        #expect(contents.entries.count == threads * perThread)
        #expect(contents.skippedLineCount == 0)
        #expect(!contents.hasTruncatedTail)
        // 同一條執行緒寫的紀錄，彼此的先後順序不變
        for thread in 0..<threads {
            let times = contents.entries.compactMap { entry -> Double? in
                guard case .translation(let text) = entry else { return nil }
                let seconds = text.at.seconds
                return Int(seconds) / 1_000 == thread ? seconds : nil
            }
            #expect(times == times.sorted())
            #expect(times.count == perThread)
        }
    }

    @Test("空的日誌讀出來沒有紀錄；檔案不存在則丟出錯誤")
    func emptyAndMissing() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")

        let writer = try JournalWriter(url: url)
        writer.close()
        #expect(try JournalReader.read(url) == JournalContents())

        #expect(throws: (any Error).self) {
            try JournalReader.read(tmp.url.appendingPathComponent("missing.jsonl"))
        }
    }
}

@Suite(
    "效能預算 Perf：日誌",
    .enabled(if: Perf.isOptimizedBuild, "效能測試只在 release 模式有意義，請用 make test-perf 執行"),
    .serialized)
struct JournalPerfTests {
    @Test("追加一筆字幕的平均時間在預算內")
    func appendCost() throws {
        let budgets = try PerfBudgets.load()
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("journal.jsonl")
        let writer = try JournalWriter(url: url)
        let count = 20_000
        let entry = JournalEntry.translation(
            CaptionText(
                text: "今天我們要談的是如何打造可以上線的 Agent，並且把它部署到三個可用區域。", kind: .segmentEnd,
                at: AudioTime(seconds: 12.5)))

        let start = ContinuousClock.now
        for _ in 0..<count { try writer.append(entry) }
        let elapsed = ContinuousClock.now - start
        writer.close()

        #expect(try JournalReader.read(url).entries.count == count)
        let microsecondsPerAppend = elapsed.seconds * 1_000_000 / Double(count)
        let budget = try budgets.maximum("journal.append.microseconds.max")
        #expect(microsecondsPerAppend <= budget, "每筆 \(microsecondsPerAppend) 微秒，預算 \(budget) 微秒")
    }
}
