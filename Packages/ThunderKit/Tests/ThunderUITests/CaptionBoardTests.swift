import Foundation
import Testing
import ThunderCore
import ThunderTestKit
import ThunderUI

private func delta(_ text: String, _ segment: Int?, at seconds: Double = 0) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .delta, at: AudioTime(seconds: seconds), segment: segment))
}

private func ended(_ text: String, _ segment: Int?, at seconds: Double = 0) -> CaptionEvent {
    .source(CaptionText(text: text, kind: .segmentEnd, at: AudioTime(seconds: seconds), segment: segment))
}

private func provisional(_ text: String, _ segment: Int?) -> CaptionEvent {
    .provisional(CaptionText(text: text, kind: .delta, at: .zero, segment: segment))
}

private func final(_ text: String, _ segment: Int?) -> CaptionEvent {
    .translation(CaptionText(text: text, kind: .segmentEnd, at: .zero, segment: segment))
}

private func board(_ events: [CaptionEvent]) -> CaptionBoard {
    var board = CaptionBoard()
    for event in events { board.apply(event) }
    return board
}

@Suite("字幕畫面的內容")
struct CaptionBoardTests {
    @Test("英文一個字一個字加在進行中的那一行；一段確定後變成一行，進行中的那一行清空")
    func english() {
        var board = board([delta(" Today", 0), delta(" I", 0), delta(" want", 0)])
        #expect(board.liveEnglish == " Today I want")
        #expect(board.liveSegment == 0)
        #expect(board.lines.isEmpty)

        board.apply(ended("Today I want to talk.", 0, at: 3.2))
        #expect(board.liveEnglish.isEmpty)
        #expect(board.lines.map(\.english) == ["Today I want to talk."])
        #expect(board.lines.first?.at == AudioTime(seconds: 3.2))

        board.apply(delta(" Next", 1))
        #expect(board.liveEnglish == " Next")
        #expect(board.liveSegment == 1)
    }

    @Test("暫定譯文顯示在正在說的那一段；這一段確定後跟著那一行，定稿到了就取代它，之後不再出現")
    func provisionalThenFinal() throws {
        var board = board([delta(" Today I want", 0), provisional("今天我", 0), provisional("今天我想", 0)])
        #expect(board.liveChinese == "今天我想")

        board.apply(ended("Today I want to talk.", 0))
        #expect(board.liveChinese.isEmpty)
        var line = try #require(board.lines.first)
        #expect(line.chinese.isEmpty)
        #expect(board.chinese(for: line, showingProvisional: true) == "今天我想")

        board.apply(final("今天我想談談。", 0))
        line = try #require(board.lines.first)
        #expect(line.chinese == "今天我想談談。")
        #expect(line.provisional.isEmpty)
        #expect(board.chinese(for: line, showingProvisional: true) == "今天我想談談。")

        // 晚到的暫定譯文不會蓋掉定稿
        board.apply(provisional("今天", 0))
        #expect(board.lines.first?.chinese == "今天我想談談。")
        #expect(board.lines.first?.provisional.isEmpty == true)
    }

    @Test("關閉暫定譯文：定稿到之前不顯示中文")
    func provisionalHidden() throws {
        let board = board([delta(" Hello there", 0), provisional("哈囉", 0), ended("Hello there.", 0)])
        let line = try #require(board.lines.first)
        #expect(board.chinese(for: line, showingProvisional: false).isEmpty)
        #expect(board.chinese(for: line, showingProvisional: true) == "哈囉")
    }

    @Test("中文定稿比下一段英文晚到：仍然排在它自己那一段")
    func lateTranslation() {
        let board = board([
            ended("First.", 0), delta(" Second", 1), provisional("第二", 1), ended("Second.", 1), delta(" Third", 2),
            final("第一。", 0), final("第二。", 1),
        ])
        #expect(board.lines.map(\.chinese) == ["第一。", "第二。"])
        #expect(board.lines.map(\.id) == [0, 1])
        #expect(board.liveEnglish == " Third")
    }

    @Test("沒翻到的段：後面的段已經有定稿，前面的還沒有，就標示未翻譯；引擎結束時剩下的也標示")
    func untranslated() {
        var board = board([ended("Zero.", 0), ended("One.", 1), ended("Two.", 2), ended("Three.", 3), final("零。", 0), final("二。", 2)])
        #expect(board.lines.map(\.untranslated) == [false, true, false, false])

        board.engineEnded()
        #expect(board.lines.map(\.untranslated) == [false, true, false, true])
        #expect(board.lines.map(\.chinese) == ["零。", "", "二。", ""])

        // 之後補翻回來（例如這一段併入尾巴後重新翻譯）：不再標示
        board.apply(final("一。", 1))
        #expect(board.lines.dropFirst().first?.untranslated == false)
    }

    @Test("補上晚到的標點：同一行的英文更新，中文不動，行數不變")
    func amended() {
        let board = board([ended("Hello world", 0), final("哈囉，世界", 0), delta(" Next", 1), ended("Hello world.", 0)])
        #expect(board.lines.count == 1)
        #expect(board.lines.first?.english == "Hello world.")
        #expect(board.lines.first?.chinese == "哈囉，世界")
    }

    @Test("併入晚到的尾巴：尾巴從進行中的那一行移到上一行，新的定稿取代舊的")
    func extended() {
        var board = board([
            ended("we are going to the", 0), final("我們要去", 0), delta(" conference.", 1), provisional("研討會", 1),
            ended("we are going to the conference.", 0),
        ])
        #expect(board.lines.count == 1)
        #expect(board.lines.first?.english == "we are going to the conference.")
        #expect(board.liveEnglish.isEmpty, "尾巴已經併進上一行")
        #expect(board.liveChinese.isEmpty)

        board.apply(final("我們要去參加研討會。", 0))
        #expect(board.lines.first?.chinese == "我們要去參加研討會。")

        board.apply(delta(" It starts", 1))
        board.apply(ended("It starts at nine.", 1))
        #expect(board.lines.map(\.id) == [0, 1])
    }

    @Test("不分段的引擎（沒有段號）：英文一句一行，中文照順序配對")
    func unsegmented() {
        let board = board([ended("en 1", nil), final("中文 1", nil), ended("en 2", nil), ended("en 3", nil), final("中文 2", nil)])
        #expect(board.lines.map(\.english) == ["en 1", "en 2", "en 3"])
        #expect(board.lines.map(\.chinese) == ["中文 1", "中文 2", ""])
    }

    @Test("第 8 小時每個事件的處理成本，不超過第 1 分鐘的 1.5 倍", .timeLimit(.minutes(1)))
    func costDoesNotGrow() {
        var board = CaptionBoard()
        func playSegments(_ range: Range<Int>, _ board: inout CaptionBoard) -> Duration {
            let clock = ContinuousClock()
            let started = clock.now
            for segment in range {
                for word in 0..<12 { board.apply(delta(" word\(word)", segment)) }
                board.apply(provisional("暫定譯文", segment))
                board.apply(ended("twelve words in this segment", segment))
                board.apply(final("這一段的中文定稿", segment))
            }
            return clock.now - started
        }
        // 每 4 秒一段：第 1 分鐘是 15 段，8 小時是 7,200 段。各量 500 段取平均，比較開頭與結尾
        _ = playSegments(0..<200, &board)  // 暖身
        let early = playSegments(200..<700, &board)
        _ = playSegments(700..<6_700, &board)
        let late = playSegments(6_700..<7_200, &board)
        #expect(board.lines.count == 7_200)
        #expect(late < early * 1.5 + .milliseconds(2), "開頭 \(early)，結尾 \(late)")
    }
}

@Suite("即時字幕的畫面狀態")
@MainActor
struct LiveCaptionModelTests {
    @Test("事件從別的執行緒大量湧入：畫面合併更新，每秒最多約 30 次，內容一個不少")
    func coalesces() async {
        let model = LiveCaptionModel()
        let started = ContinuousClock.now
        await Task.detached {
            for segment in 0..<200 {
                for word in 0..<10 { model.receive(delta(" w\(word)", segment)) }
                model.receive(ended("ten words", segment))
                model.receive(final("十個字", segment))
                if segment % 20 == 19 { try? await Task.sleep(for: .milliseconds(20)) }
            }
        }.value
        // 在主執行緒上等畫面追上（等待時把執行緒讓出來，更新才排得進來）
        let deadline = ContinuousClock.now + .seconds(5)
        func caughtUp() -> Bool { model.board.lines.count == 200 && model.board.lines.last?.chinese == "十個字" }
        while !caughtUp(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let elapsed = ContinuousClock.now - started
        #expect(caughtUp())

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        #expect(model.updateCount >= 1)
        #expect(Double(model.updateCount) <= seconds * 31 + 2, "\(model.updateCount) 次更新，\(seconds) 秒")
        #expect(model.updateCount < 2_400 / 10, "2,400 個事件不能變成 2,400 次更新")
    }

    @Test("狀態、用量、缺口：最後的值會反映在畫面狀態上；重設之後清空")
    func statusAndUsage() async {
        let model = LiveCaptionModel()
        model.receive(.status(.connecting))
        model.receive(.status(.live))
        model.receive(.usage(audioSeconds: 12.5))
        model.receive(.gap(AudioGap(from: AudioTime(seconds: 1), to: AudioTime(seconds: 3.5), reason: .network)))
        model.receive(ended("Hello.", 0))
        model.flush()
        #expect(model.engineStatus == .live)
        #expect(model.billedSeconds == 12.5)
        #expect(model.gapSeconds == 2.5)
        #expect(model.board.lines.count == 1)

        model.engineEnded()
        #expect(model.board.lines.first?.untranslated == true)

        model.reset()
        #expect(model.board.lines.isEmpty)
        #expect(model.engineStatus == nil)
        #expect(model.billedSeconds == 0)
    }

    @Test("沒有事件時不排任何更新")
    func idle() async {
        let model = LiveCaptionModel()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(model.updateCount == 0)
    }
}
