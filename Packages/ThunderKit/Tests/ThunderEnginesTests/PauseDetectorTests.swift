import Foundation
import Testing
import ThunderCore
import ThunderEngines
import ThunderTestKit

/// 把一段測試音訊送進停頓偵測，收集所有事件。
private func detect(
    _ scene: SpeechScene,
    configuration: PauseDetector.Configuration = PauseDetector.Configuration(),
    chunkDuration: TimeInterval = 0.2,
    startTime: AudioTime = .zero
) -> [PauseDetector.Event] {
    var detector = PauseDetector(configuration: configuration)
    return scene.chunks(chunkDuration: chunkDuration, startTime: startTime).flatMap { detector.process($0) }
}

private struct Pause: Equatable {
    var speechEnd: TimeInterval
    var at: TimeInterval
}

private func pauses(in events: [PauseDetector.Event]) -> [Pause] {
    events.compactMap {
        if case .paused(let speechEnd, let at) = $0 { Pause(speechEnd: speechEnd.seconds, at: at.seconds) } else { nil }
    }
}

private func speechStarts(in events: [PauseDetector.Event]) -> [TimeInterval] {
    events.compactMap {
        if case .speechStarted(let at) = $0 { at.seconds } else { nil }
    }
}

/// 事件的種類與順序相同，時間相差在 `tolerance` 之內。
private func sameEvents(_ first: [PauseDetector.Event], _ second: [PauseDetector.Event], tolerance: TimeInterval = 1e-6) -> Bool {
    guard first.count == second.count else { return false }
    return zip(first, second).allSatisfy { pair in
        switch pair {
        case (.speechStarted(let a), .speechStarted(let b)):
            abs(a.seconds - b.seconds) <= tolerance
        case (.paused(let endA, let atA), .paused(let endB, let atB)):
            abs(endA.seconds - endB.seconds) <= tolerance && abs(atA.seconds - atB.seconds) <= tolerance
        default:
            false
        }
    }
}

/// 一格是 20 ms：語音的起訖最多差一格。
private let oneFrame = 0.02 + 1e-6

@Suite("PauseDetector：從音量判斷講者什麼時候停頓")
struct PauseDetectorTests {
    /// 說 2 秒、停 0.4 秒、再說 1.5 秒。
    private static let twoPhrases: [SpeechScene.Part] = [.silence(0.5), .speech(2.0), .silence(0.4), .speech(1.5)]

    @Test("乾淨的聲音：說話、停 0.4 秒、再說話，回報開始說話、停頓、又開始說話，時間都對得上")
    func cleanAudio() throws {
        let events = detect(SpeechScene(Self.twoPhrases))

        #expect(events.count == 3, "實際：\(events)")
        let starts = speechStarts(in: events)
        let found = pauses(in: events)
        try #require(starts.count == 2 && found.count == 1, "實際：\(events)")
        #expect(abs(starts[0] - 0.5) <= oneFrame)
        #expect(abs(found[0].speechEnd - 2.5) <= oneFrame)
        #expect(abs(found[0].at - 2.8) <= oneFrame)
        #expect(abs(starts[1] - 2.9) <= oneFrame)
        // 事件依時間順序
        if case .speechStarted = events[0], case .paused = events[1], case .speechStarted = events[2] {
        } else {
            Issue.record("順序應該是 開始說話、停頓、開始說話，實際：\(events)")
        }
    }

    @Test("偵測到停頓的時間，就是語音結束之後剛好滿 0.3 秒")
    func pauseIsReportedAfterTheSilenceDuration() throws {
        let pause = try #require(pauses(in: detect(SpeechScene(Self.twoPhrases))).first)
        #expect(abs((pause.at - pause.speechEnd) - 0.3) <= 1e-6)
    }

    @Test("底噪很高（現場收音）也偵測得到：時間和乾淨的聲音一樣")
    func noisyRoom() throws {
        // 底噪 500：比合成語音實驗時用的固定門檻（100）高，固定門檻在這種錄音上偵測不到任何停頓
        let events = detect(SpeechScene(Self.twoPhrases, noiseRMS: 500))

        let starts = speechStarts(in: events)
        let found = pauses(in: events)
        #expect(events.count == 3, "實際：\(events)")
        try #require(starts.count == 2 && found.count == 1, "實際：\(events)")
        #expect(abs(starts[0] - 0.5) <= oneFrame)
        #expect(abs(found[0].speechEnd - 2.5) <= oneFrame)
        #expect(abs(found[0].at - 2.8) <= oneFrame)
        #expect(abs(starts[1] - 2.9) <= oneFrame)
    }

    @Test("停不到 0.3 秒不算停頓", arguments: [0.0, 500.0])
    func shortGapIsNotAPause(noise: Double) {
        let events = detect(SpeechScene([.silence(0.5), .speech(2.0), .silence(0.2), .speech(2.0)], noiseRMS: noise))

        #expect(pauses(in: events).isEmpty)
        #expect(speechStarts(in: events).count == 1)
    }

    @Test("沒有人說話就沒有任何事件：數位靜音與只有底噪都一樣", arguments: [0.0, 200.0, 500.0, 1500.0])
    func silenceProducesNoEvents(noise: Double) {
        #expect(detect(SpeechScene([.silence(30)], noiseRMS: noise)).isEmpty)
    }

    @Test("單獨一格的聲響不算開始說話")
    func singleLoudFrameIsIgnored() {
        #expect(detect(SpeechScene([.silence(1.0), .speech(0.02), .silence(1.0)])).isEmpty)
    }

    @Test("一開始就在說話：第一次停頓照樣偵測得到")
    func speechFromTheVeryStart() {
        let events = detect(SpeechScene([.speech(3.0), .silence(0.5), .speech(2.0)], noiseRMS: 500))

        let found = pauses(in: events)
        #expect(found.count == 1, "實際：\(events)")
        if let pause = found.first {
            #expect(abs(pause.speechEnd - 3.0) <= oneFrame)
            #expect(abs(pause.at - 3.3) <= oneFrame)
        }
        // 剛開始還分不出底噪與語音，開始說話的回報可以晚一點，但不能晚太多
        #expect((speechStarts(in: events).first ?? .infinity) <= 0.3)
    }

    @Test("連續說 60 秒、音節之間的起伏不會被當成停頓", arguments: [0.0, 500.0])
    func longContinuousSpeech(noise: Double) {
        let events = detect(SpeechScene([.silence(1.0), .speech(60)], noiseRMS: noise))

        #expect(pauses(in: events).isEmpty)
        #expect(speechStarts(in: events).count == 1)
    }

    @Test("底噪與音量都變大之後，門檻會跟著調整：穩定下來之後每一次停頓都偵測得到，也沒有多出來的")
    func adaptsWhenTheNoiseFloorChanges() {
        let cycle: [SpeechScene.Part] = [.speech(2.0), .silence(0.5)]
        // 前 25 秒：安靜的環境。後 45 秒：底噪 6 倍、講者也大聲得多（例如換了收音位置）。
        let quiet = SpeechScene(Array(repeating: cycle, count: 10).flatMap { $0 }, amplitude: 0.2, noiseRMS: 200)
        let loud = SpeechScene(Array(repeating: cycle, count: 18).flatMap { $0 }, amplitude: 0.5, noiseRMS: 1200, seed: 2)
        let scene = quiet + loud
        let found = pauses(in: detect(scene))

        func check(from: TimeInterval, to: TimeInterval, _ label: Comment) {
            let expected = scene.speechIntervals.map(\.upperBound).filter { $0 >= from && $0 < to }
            let detected = found.map(\.speechEnd).filter { $0 >= from - 0.1 && $0 < to - 0.1 }
            #expect(detected.count == expected.count, label)
            for end in expected {
                #expect(detected.contains { abs($0 - end) <= 2 * oneFrame }, "\(label)：\(end) 秒的停頓沒有偵測到")
            }
        }
        check(from: 0, to: 25, "安靜的環境")
        // 時間窗是 20 秒：環境改變 25 秒之後應該已經穩定
        check(from: 50, to: 70, "變吵之後")
    }

    @Test("包怎麼切都一樣：200 ms、20 ms、37 ms、整段一包，事件完全相同")
    func chunkingDoesNotMatter() {
        let scene = SpeechScene(Self.twoPhrases + [.silence(0.6), .speech(1.0), .silence(0.5)], noiseRMS: 500)
        let reference = detect(scene, chunkDuration: 0.2)

        #expect(pauses(in: reference).count == 3)
        for chunkDuration in [0.02, 0.037, scene.duration] {
            let events = detect(scene, chunkDuration: chunkDuration)
            #expect(sameEvents(events, reference), "每包 \(chunkDuration) 秒：\(events)")
        }
    }

    @Test("事件的時間是音訊時間：音訊從第 100 秒開始，事件也從那裡算起")
    func eventTimesFollowTheAudioClock() {
        let scene = SpeechScene(Self.twoPhrases, noiseRMS: 500)
        let atZero = detect(scene)
        let shifted = detect(scene, startTime: AudioTime(seconds: 100))

        #expect(shifted.count == atZero.count)
        let moved = atZero.map { event -> PauseDetector.Event in
            switch event {
            case .speechStarted(let at): .speechStarted(at: at + 100)
            case .paused(let speechEnd, let at): .paused(speechEnd: speechEnd + 100, at: at + 100)
            }
        }
        #expect(sameEvents(shifted, moved))
    }

    @Test("音訊時間不連續（中間有一段沒有送到）：之後的時間跟著新的音訊走，缺的那一段不算停頓")
    func gapInTheAudioClock() {
        var detector = PauseDetector()
        var events: [PauseDetector.Event] = []
        // 0–2.5 秒：停 0.5 秒後開始說話。接著 2.5–10 秒的音訊沒有送到（例如等待區滿了被丟掉）。
        for chunk in SpeechScene([.silence(0.5), .speech(2.0)]).chunks() { events += detector.process(chunk) }
        // 第 10 秒起：還在說話，1 秒後停下來。
        for chunk in SpeechScene([.speech(1.0), .silence(0.5)]).chunks(startTime: AudioTime(seconds: 10)) {
            events += detector.process(chunk)
        }

        #expect(speechStarts(in: events).count == 1)
        let found = pauses(in: events)
        #expect(found.count == 1, "實際：\(events)")
        if let pause = found.first {
            #expect(abs(pause.speechEnd - 11.0) <= oneFrame)
            #expect(abs(pause.at - 11.3) <= oneFrame)
        }
    }

    @Test("靜音要多久才算停頓可以設定")
    func silenceDurationIsConfigurable() {
        var configuration = PauseDetector.Configuration()
        configuration.silenceDuration = 0.5
        let scene = SpeechScene([.silence(0.5), .speech(2.0), .silence(0.4), .speech(2.0), .silence(0.6), .speech(1.0)])
        let found = pauses(in: detect(scene, configuration: configuration))

        #expect(found.count == 1)
        if let pause = found.first {
            #expect(abs(pause.speechEnd - 4.9) <= oneFrame)
            #expect(abs(pause.at - 5.4) <= oneFrame)
        }
    }

    @Test("門檻：沒有音訊時是下限；有底噪時落在底噪與語音之間")
    func thresholdSitsBetweenNoiseAndSpeech() {
        var detector = PauseDetector()
        #expect(detector.threshold == PauseDetector.Configuration().minimumThreshold)

        // 語音有聲部分的音量約 4,600，底噪 500
        for chunk in SpeechScene(Self.twoPhrases, noiseRMS: 500).chunks() { _ = detector.process(chunk) }
        #expect(detector.threshold > 550)
        #expect(detector.threshold < 4000)

        // 數位靜音加上語音：門檻不低於下限，也遠低於語音
        var clean = PauseDetector()
        for chunk in SpeechScene(Self.twoPhrases).chunks() { _ = clean.process(chunk) }
        #expect(clean.threshold >= PauseDetector.Configuration().minimumThreshold)
        #expect(clean.threshold < 1000)
    }

    @Test("isSpeaking 跟著事件變化")
    func isSpeakingFollowsTheEvents() {
        var detector = PauseDetector()
        #expect(!detector.isSpeaking)
        let chunks = SpeechScene([.silence(0.4), .speech(1.0), .silence(0.6)], noiseRMS: 500).chunks()
        // 前 1.2 秒：已經開始說話
        for chunk in chunks.prefix(6) { _ = detector.process(chunk) }
        #expect(detector.isSpeaking)
        // 全部送完：已經停頓
        for chunk in chunks.dropFirst(6) { _ = detector.process(chunk) }
        #expect(!detector.isSpeaking)
    }
}
