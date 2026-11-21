import Foundation
import Testing
import ThunderCore
import ThunderTestKit

/// 日誌裡的一筆英文。`end` 為 false 時是增量文字。
private func src(_ text: String, at time: Double, seg: Int? = nil, end: Bool = true) -> JournalEntry {
    .source(CaptionText(text: text, kind: end ? .segmentEnd : .delta, at: AudioTime(seconds: time), segment: seg))
}

/// 日誌裡的一筆中文定稿。
private func tr(_ text: String, at time: Double, seg: Int? = nil) -> JournalEntry {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: time), segment: seg))
}

/// 每一段只有一筆確定的英文，段號從 0 開始依序編。
private func segments(_ items: [(time: Double, text: String)]) -> [JournalEntry] {
    items.enumerated().map { src($1.text, at: $1.time, seg: $0) }
}

private func pause(at time: Double) -> [JournalEntry] {
    [.paused(at: AudioTime(seconds: time)), .resumed(at: AudioTime(seconds: time))]
}

/// 基本段落（DESIGN.md 5.7.1 節）：結束處理的第 2 步，不需要網路。
@Suite("基本段落：把日誌裡相鄰的段合成段落")
struct TranscriptBlocksBuildTests {
    @Test("相鄰的段合成一個段落：英文以空白相接，中文依段號配對（晚到也配得上），時間是第一個字減 2 秒")
    func mergesAdjacentSegments() {
        let result = TranscriptBlocks.build(from: [
            src("So today we're going to talk about agents.", at: 12.5, seg: 0),
            src("They can call tools.", at: 17, seg: 1),
            tr("今天我們要談的是 Agent。", at: 17.5, seg: 0),  // 中文定稿比下一段英文晚到
            src("And they remember things.", at: 21, seg: 2),
            tr("而且它們會記住事情。", at: 22, seg: 2),
            tr("它們可以呼叫工具。", at: 22.5, seg: 1),
        ])

        #expect(
            result.blocks == [
                TranscriptBlock(
                    id: 0, start: 10.5,
                    en: "So today we're going to talk about agents. They can call tools. And they remember things.",
                    zh: "今天我們要談的是 Agent。它們可以呼叫工具。而且它們會記住事情。",
                    segments: [0, 1, 2], marked: false)
            ])
        #expect(result.untranslatedSegments == 0)
    }

    @Test("段落滿 20 秒之後，在句尾結束；還不到 20 秒的句尾不結束")
    func closesAtSentenceEndAfterTwentySeconds() {
        let result = TranscriptBlocks.build(
            from: segments([(10, "One."), (16, "Two."), (22, "Three,"), (28.5, "four."), (30.5, "Five."), (36, "Six.")]))

        #expect(result.blocks.map(\.segments) == [[0, 1, 2, 3, 4], [5]])
        #expect(result.blocks.map(\.en) == ["One. Two. Three, four. Five.", "Six."])
        #expect(result.blocks.map(\.start) == [8, 34])
        #expect(result.blocks.map(\.id) == [0, 1])
    }

    @Test(
        "句尾的判斷：中英文的句號、問號、驚嘆號，後面可以跟著引號或括號",
        arguments: ["Done.", "Really?", "Wow!", "他說完了。", "真的嗎？", "太好了！", "She said \"go.\"", "(really?)", "他說：「好。」"])
    func recognisesSentenceEnds(ending: String) {
        let result = TranscriptBlocks.build(from: segments([(0, "start"), (21, ending), (22, "next")]))

        #expect(result.blocks.map(\.segments) == [[0, 1], [2]])
    }

    @Test("不是句尾就不結束段落", arguments: ["and then,", "we", "so…", "version 2"])
    func ignoresOtherEndings(ending: String) {
        let result = TranscriptBlocks.build(from: segments([(0, "start"), (21, ending), (22, "next")]))

        #expect(result.blocks.map(\.segments) == [[0, 1, 2]])
    }

    @Test("段落滿 20 秒之後，下一段在 2 秒以上的停頓之後才開始，就結束段落；不到 20 秒或停頓不到 2 秒不結束")
    func closesAtSilenceAfterTwentySeconds() {
        let result = TranscriptBlocks.build(
            from: segments([
                (10, "a"), (15, "b"), (20, "c"), (25, "d"), (31, "e"), (32.5, "f"), (35, "g"), (38, "h"),
            ]))

        #expect(result.blocks.map(\.segments) == [[0, 1, 2, 3, 4, 5], [6, 7]])
        #expect(result.blocks.map(\.start) == [8, 33])
    }

    @Test("停頓的長度從上一段最後一個字算起，不是從它確定的時間算起")
    func silenceIsMeasuredFromTheLastWord() {
        let result = TranscriptBlocks.build(from: [
            src("alpha", at: 5, seg: 0),
            src("beta", at: 26, seg: 1),
            src(" gamma", at: 27, seg: 2, end: false),
            src("gamma", at: 29, seg: 2),  // 2 秒沒有新的字才確定
            src(" delta", at: 29.5, seg: 3, end: false),
            src("delta", at: 30, seg: 3),
        ])

        #expect(result.blocks.map(\.segments) == [[0, 1, 2], [3]])
    }

    @Test("段落不超過 60 秒：加上下一段會超過時，先結束段落")
    func neverExceedsSixtySeconds() {
        // 每 1.5 秒一段、沒有句尾也沒有停頓，一共 199.5 秒
        let result = TranscriptBlocks.build(from: segments((0..<134).map { (Double($0) * 1.5, "w\($0)") }))

        #expect(
            result.blocks.map(\.segments) == [Array(0...40), Array(41...81), Array(82...122), Array(123...133)])
        #expect(result.blocks.map(\.start) == [0, 59.5, 121, 182.5])
    }

    @Test("暫停一定結束段落；依音訊時間判斷，不看暫停紀錄在日誌裡的位置")
    func pauseClosesTheBlock() {
        let inOrder = TranscriptBlocks.build(
            from: [src("Before the break", at: 10, seg: 0), src("we stop here", at: 13, seg: 1)] + pause(at: 15)
                + [src("Welcome back", at: 15.6, seg: 2), src("let's continue", at: 18, seg: 3)])
        #expect(inOrder.blocks.map(\.segments) == [[0, 1], [2, 3]])
        #expect(inOrder.blocks.map(\.start) == [8, 13.6])

        // 暫停前說的話，寫進日誌時使用者已經按了暫停
        let lateText = TranscriptBlocks.build(
            from: [src("Before the break", at: 10, seg: 0), .paused(at: AudioTime(seconds: 15))]
                + [src("we stop here", at: 14.8, seg: 1), .resumed(at: AudioTime(seconds: 15))]
                + [src("Welcome back", at: 15.6, seg: 2)])
        #expect(lateText.blocks.map(\.segments) == [[0, 1], [2]])

        // 暫停時還沒說完的那一段，暫停之後才確定：仍然屬於暫停前的段落
        let spanning = TranscriptBlocks.build(
            from: [src(" and so", at: 14, seg: 0, end: false), .paused(at: AudioTime(seconds: 15))]
                + [src("and so we stop", at: 15, seg: 0), .resumed(at: AudioTime(seconds: 15))]
                + [src("Welcome back", at: 15.6, seg: 1)])
        #expect(spanning.blocks.map(\.en) == ["and so we stop", "Welcome back"])
    }

    @Test("同一個段號有好幾筆確定的紀錄時，以最後一筆為準（補上晚到的標點、重新翻譯）")
    func lastEntryWins() {
        let result = TranscriptBlocks.build(from: [
            src(" Hello", at: 10, seg: 0, end: false),
            src(" world", at: 10.4, seg: 0, end: false),
            src("Hello world", at: 10.8, seg: 0),
            tr("哈囉，世界", at: 11.5, seg: 0),
            src("Hello world.", at: 11.9, seg: 0),  // 晚到的句號
            tr("哈囉，世界。", at: 12.6, seg: 0),
            src("We built it", at: 14, seg: 1),
            tr("我們做出來了", at: 15, seg: 1),
            src("We built it today.", at: 15.5, seg: 1),  // 併入晚到的尾巴
            tr("我們今天做出來了。", at: 16.5, seg: 1),  // 重新翻譯
        ])

        #expect(
            result.blocks == [
                TranscriptBlock(
                    id: 0, start: 8, en: "Hello world. We built it today.", zh: "哈囉，世界。我們今天做出來了。",
                    segments: [0, 1], marked: false)
            ])
        #expect(result.untranslatedSegments == 0)
    }

    @Test("沒有中文定稿的段留空，並計入沒翻到的段數；整個段落都沒翻到時中文是空字串")
    func untranslatedSegmentsAreCounted() {
        let result = TranscriptBlocks.build(
            from: [
                src("One.", at: 10, seg: 0), tr("第一。", at: 11, seg: 0),
                src("Two.", at: 12, seg: 1), tr("  ", at: 13, seg: 1),  // 空白的譯文等於沒翻到
                src("Three.", at: 14, seg: 2), tr("第三。", at: 15, seg: 2),
            ] + pause(at: 16) + [src("Four.", at: 17, seg: 3), src("Five.", at: 19, seg: 4)])

        #expect(result.blocks.map(\.en) == ["One. Two. Three.", "Four. Five."])
        #expect(result.blocks.map(\.zh) == ["第一。第三。", ""])
        #expect(result.blocks.map(\.segments) == [[0, 1, 2], [3, 4]])
        #expect(result.untranslatedSegments == 3)
    }

    @Test("沒有段號的舊日誌：每一筆確定的英文自成一段，中文依順序配對")
    func journalsWithoutSegmentNumbers() {
        let result = TranscriptBlocks.build(from: [
            src("Fir", at: 9.5, end: false),
            src("First sentence.", at: 10), tr("第一句。", at: 11),
            src("Second sentence.", at: 14), tr("第二句。", at: 15),
            src("Third sentence.", at: 18),
        ])

        #expect(
            result.blocks == [
                TranscriptBlock(
                    id: 0, start: 7.5, en: "First sentence. Second sentence. Third sentence.", zh: "第一句。第二句。",
                    segments: [0, 1, 2], marked: false)
            ])
        #expect(result.untranslatedSegments == 1)
    }

    @Test("日誌結尾只有增量文字、沒有確定的紀錄（錄音中當掉）：把增量文字接起來當成最後一段")
    func unfinishedLastSegment() {
        let numbered = TranscriptBlocks.build(from: [
            src("Complete one.", at: 10, seg: 0), tr("完整的一段。", at: 11, seg: 0),
            src(" And then", at: 12, seg: 1, end: false),
            src(" the power", at: 12.4, seg: 1, end: false),
            src(" went", at: 12.8, seg: 1, end: false),
        ])
        #expect(numbered.blocks.map(\.en) == ["Complete one. And then the power went"])
        #expect(numbered.blocks.map(\.zh) == ["完整的一段。"])
        #expect(numbered.blocks.map(\.segments) == [[0, 1]])
        #expect(numbered.untranslatedSegments == 1)

        let unnumbered = TranscriptBlocks.build(from: [
            src("Complete one.", at: 10),
            src(" And then", at: 12, end: false),
            src(" it stopped", at: 12.4, end: false),
        ])
        #expect(unnumbered.blocks.map(\.en) == ["Complete one. And then it stopped"])
        #expect(unnumbered.blocks.map(\.segments) == [[0, 1]])
    }

    @Test("晚到的尾巴併回上一段之後，它先前當成下一段送出的增量文字作廢，不會重複出現")
    func lateTailIsNotDuplicated() {
        let merged: [JournalEntry] = [
            src("We built the thing", at: 10, seg: 0),
            src(" today.", at: 10.5, seg: 1, end: false),  // 晚到的尾巴，先當成下一段的增量文字送出
            src("We built the thing today.", at: 10.7, seg: 0),  // 併回上一段
        ]
        let stoppedThere = TranscriptBlocks.build(from: merged)
        #expect(stoppedThere.blocks.map(\.en) == ["We built the thing today."])
        #expect(stoppedThere.blocks.map(\.segments) == [[0]])

        // 下一段重新開始之後才中斷
        let continued = TranscriptBlocks.build(
            from: merged + [src(" Next", at: 12, seg: 1, end: false), src(" up", at: 12.3, seg: 1, end: false)])
        #expect(continued.blocks.map(\.en) == ["We built the thing today. Next up"])
        #expect(continued.blocks.map(\.segments) == [[0, 1]])
    }

    /// 三個段落：第一個字分別在 10、36、70 秒出現。
    private static let threeBlocks: [(time: Double, text: String)] = [
        (10, "One."), (16, "Two."), (22, "Three,"), (28.5, "four."), (30.5, "Five."),
        (36, "Six."), (42, "Seven."), (48, "Eight."), (54, "Nine."), (58, "Ten."),
        (70, "Last one."),
    ]

    @Test(
        "重點標記標在當下第一個字已經出現的最後一個段落；比所有段落都早的標記算在第一個段落",
        arguments: [
            ([], [false, false, false]),
            ([5.0], [true, false, false]),
            ([33.0], [true, false, false]),
            ([36.0], [false, true, false]),
            ([100.0], [false, false, true]),
            ([20.0, 60.0, 61.0], [true, true, false]),
        ] as [([Double], [Bool])])
    func marksFlagTheBlockTheyFallIn(marks: [Double], expected: [Bool]) {
        // 標記由另一條執行緒寫進日誌，位置不固定：這裡全部放在最後
        let entries = segments(Self.threeBlocks) + marks.map { JournalEntry.marker(at: AudioTime(seconds: $0)) }

        let result = TranscriptBlocks.build(from: entries)

        #expect(result.blocks.map(\.segments) == [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10]])
        #expect(result.blocks.map(\.marked) == expected)
    }

    @Test("段落的時間：第一個字（第一筆增量文字）減 2 秒，四捨五入到毫秒，不小於 0，而且只增不減")
    func startTimes() {
        let fromFirstDelta = TranscriptBlocks.build(from: [
            src(" Hello", at: 10, seg: 0, end: false), src("Hello there.", at: 13, seg: 0),
        ])
        #expect(fromFirstDelta.blocks.map(\.start) == [8])

        #expect(TranscriptBlocks.build(from: segments([(1.2, "Early.")])).blocks.map(\.start) == [0])
        #expect(TranscriptBlocks.build(from: segments([(12.3456789, "Odd.")])).blocks.map(\.start) == [10.346])

        // 日誌裡的時間倒退了：段落的時間仍然不會比前一個段落早
        let backwards = TranscriptBlocks.build(from: segments([(50, "A."), (71, "B."), (40, "C.")]))
        #expect(backwards.blocks.map(\.segments) == [[0, 1], [2]])
        #expect(backwards.blocks.map(\.start) == [48, 48])
    }

    @Test(
        "中文直接相接；兩邊都是英數字、或一邊中文一邊英數字時補一個空白",
        arguments: [
            (["今天我想談談", "我們怎麼做。"], "今天我想談談我們怎麼做。"),
            (["使用 AgentCore", "Runtime 時"], "使用 AgentCore Runtime 時"),
            (["有 3", "個元件"], "有 3 個元件"),
            (["第一句。", "Amazon 提供"], "第一句。Amazon 提供"),
            (["接下來介紹 Amazon Bedrock", "的三個核心元件"], "接下來介紹 Amazon Bedrock 的三個核心元件"),
            (["他說：", "「好」"], "他說：「好」"),
        ] as [([String], String)])
    func joinsChineseText(parts: [String], expected: String) {
        var entries: [JournalEntry] = []
        for (index, part) in parts.enumerated() {
            entries.append(src("s\(index)", at: Double(index), seg: index))
            entries.append(tr(part, at: Double(index) + 0.5, seg: index))
        }

        #expect(TranscriptBlocks.build(from: entries).blocks.map(\.zh) == [expected])
    }

    @Test("文字裡的換行收成一行；沒有英文的段不進段落；對不上英文的中文不採用")
    func tidiesText() {
        let result = TranscriptBlocks.build(from: [
            src("line one\nline two", at: 10, seg: 0), tr("第一行\n第二行", at: 11, seg: 0),
            src("   ", at: 12, seg: 1), tr("沒有英文的中文", at: 13, seg: 1),
            tr("對不上任何一段", at: 14, seg: 9),
            src("end.", at: 15, seg: 2),
        ])

        #expect(
            result.blocks == [
                TranscriptBlock(
                    id: 0, start: 8, en: "line one line two end.", zh: "第一行第二行", segments: [0, 2], marked: false)
            ])
        #expect(result.untranslatedSegments == 1)
    }

    @Test("沒有字幕的日誌：沒有段落")
    func emptyJournal() {
        #expect(TranscriptBlocks.build(from: []) == TranscriptBlocks.BuildResult(blocks: [], untranslatedSegments: 0))
        let noText: [JournalEntry] =
            pause(at: 3) + [
                .marker(at: AudioTime(seconds: 5)),
                .gap(AudioGap(from: AudioTime(seconds: 1), to: AudioTime(seconds: 2), reason: .network)),
            ]
        #expect(TranscriptBlocks.build(from: noText).blocks.isEmpty)
    }

    @Test("隨機產生的日誌：每一段恰好屬於一個段落、順序不變，時間只增不減，暫停兩邊不會在同一個段落")
    func invariantsHoldForRandomJournals() {
        var generator = SeededGenerator(seed: 20_261_121)
        for _ in 0..<30 {
            var entries: [JournalEntry] = []
            var texts: [String] = []
            var firstWord: [Double] = []
            var lastWord: [Double] = []
            var translated = 0
            var pauses: [Double] = []
            var time = 0.0
            let count = Int.random(in: 1...120, using: &generator)
            for segment in 0..<count {
                time += Double.random(in: 0.3...9, using: &generator)
                if segment > 0, Int.random(in: 0..<25, using: &generator) == 0 {
                    entries += pause(at: time)
                    pauses.append(time)
                    time += 0.1
                }
                let text = "w\(segment)" + ([".", ",", "", "?"].randomElement(using: &generator) ?? "")
                let hasDelta = Bool.random(using: &generator)
                let hasDraft = Int.random(in: 0..<10, using: &generator) == 0
                if hasDelta { entries.append(src(" w\(segment)", at: time, seg: segment, end: false)) }
                if hasDraft { entries.append(src("draft \(segment)", at: time + 0.05, seg: segment)) }
                entries.append(src(text, at: time + 0.1, seg: segment))
                texts.append(text)
                firstWord.append(hasDelta ? time : hasDraft ? time + 0.05 : time + 0.1)
                lastWord.append(hasDelta ? time : hasDraft ? time + 0.05 : time + 0.1)
                if Int.random(in: 0..<4, using: &generator) != 0 {
                    entries.append(tr("譯\(segment)。", at: time + 0.2, seg: segment))
                    translated += 1
                }
                time += 0.2
            }

            let result = TranscriptBlocks.build(from: entries)

            #expect(result.blocks.map(\.id) == Array(result.blocks.indices))
            #expect(result.blocks.flatMap(\.segments) == Array(0..<count))
            #expect(result.blocks.map(\.en).joined(separator: " ") == texts.joined(separator: " "))
            #expect(result.untranslatedSegments == count - translated)
            #expect(result.blocks.map(\.start) == result.blocks.map(\.start).sorted())
            #expect(result.blocks.allSatisfy { $0.start >= 0 })
            for block in result.blocks {
                guard let first = block.segments.first, let last = block.segments.last, first != last else { continue }
                #expect(lastWord[last] - firstWord[first] <= 60, "段落 \(block.id) 超過 60 秒")
                #expect(!pauses.contains { firstWord[first] <= $0 && $0 < firstWord[last] }, "段落 \(block.id) 跨過了暫停")
            }
            #expect(TranscriptBlocks.build(from: entries) == result)
        }
    }
}

@Suite("blocks.jsonl：一行一段")
struct TranscriptBlocksFileTests {
    private let sample = [
        TranscriptBlock(id: 0, start: 10.5, en: "Hello \"world\".", zh: "你好，世界。", segments: [0, 1], marked: false),
        TranscriptBlock(id: 1, start: 34, en: "Path a/b\\c", zh: "", segments: [2], marked: true),
    ]

    @Test("一行一段、欄位順序固定、文字以 UTF-8 原文存放；讀回來一模一樣")
    func lineFormat() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")

        try TranscriptBlocks.write(sample, to: url)

        let expected = """
            {"id":0,"start":10.5,"en":"Hello \\"world\\".","zh":"你好，世界。","segments":[0,1],"marked":false}
            {"id":1,"start":34,"en":"Path a/b\\\\c","zh":"","segments":[2],"marked":true}

            """
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        #expect(try TranscriptBlocks.read(url) == sample)
    }

    @Test("引號、反斜線、換行、控制字元、表情符號都能原樣讀回來，而且仍然是一行一段")
    func roundTripsAwkwardText() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")
        let blocks = [
            TranscriptBlock(
                id: 0, start: 0, en: "He said \"hi\" \\ and/or\nleft\ttab \u{1} done", zh: "他說「嗨」😀\r\n第二行",
                segments: [0], marked: true),
            TranscriptBlock(id: 1, start: 86_399.999, en: "late", zh: "很晚", segments: [1, 2, 3], marked: false),
        ]

        try TranscriptBlocks.write(blocks, to: url)

        #expect(try TranscriptBlocks.read(url) == blocks)
        let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"))
        #expect(lines.count == 2)
    }

    @Test("最後一行寫到一半會被略過；最後一行只是少了換行時照樣採用")
    func toleratesATruncatedTail() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")
        let blocks = sample + [TranscriptBlock(id: 2, start: 60, en: "The third block.", zh: "第三段。", segments: [3])]
        try TranscriptBlocks.write(blocks, to: url)
        let complete = try Data(contentsOf: url)
        #expect(complete.count > 40)
        guard complete.count > 40 else { return }

        try complete.dropLast(20).write(to: url)
        #expect(try TranscriptBlocks.read(url) == sample)

        try complete.dropLast(1).write(to: url)
        #expect(try TranscriptBlocks.read(url) == blocks)
    }

    @Test("讀不懂的行會跳過；缺少的非必要欄位用預設值；不認識的欄位忽略")
    func tolerantReading() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")
        let text = """
            {"id":0,"start":1,"en":"minimal"}
            this is not json
            {"id":1,"start":2.5,"en":"extra","zh":"多的欄位","segments":[3],"marked":true,"future":{"x":1}}
            {"id":"wrong type","start":3,"en":"bad"}

            {"id":2,"start":4,"en":"after a blank line"}

            """
        try Data(text.utf8).write(to: url)

        #expect(
            try TranscriptBlocks.read(url) == [
                TranscriptBlock(id: 0, start: 1, en: "minimal"),
                TranscriptBlock(id: 1, start: 2.5, en: "extra", zh: "多的欄位", segments: [3], marked: true),
                TranscriptBlock(id: 2, start: 4, en: "after a blank line"),
            ])
    }

    @Test("原子寫入：整個檔案換掉、不留暫存檔；同樣的段落每次寫出來的位元組都一樣")
    func atomicAndDeterministic() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("blocks.jsonl")

        try TranscriptBlocks.write(sample, to: url)
        let first = try Data(contentsOf: url)
        try TranscriptBlocks.write(sample, to: url)
        #expect(try Data(contentsOf: url) == first)
        #expect(!first.isEmpty)

        try TranscriptBlocks.write([sample[1]], to: url)
        #expect(try TranscriptBlocks.read(url) == [sample[1]])
        try TranscriptBlocks.write([], to: url)
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(try TranscriptBlocks.read(url).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["blocks.jsonl"])
    }

    @Test("檔案不存在時丟出錯誤")
    func missingFileThrows() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }

        #expect(throws: (any Error).self) {
            try TranscriptBlocks.read(tmp.url.appendingPathComponent("blocks.jsonl"))
        }
    }
}
