# ThunderFlow 開發指令。所有邏輯都在 Packages/ThunderKit，不需要開 Xcode 就能建置與測試。

PKG := Packages/ThunderKit

.PHONY: build test test-tsan test-perf test-soak check app run measure-app measure-recording phone phone-selftest phone-install phone-testflight

## 編譯全部（含測試）
build:
	swift build --package-path $(PKG) --build-tests

## 每次提交都要跑：單元、整合、當機安全、30 分鐘記憶體測試
test:
	swift test --package-path $(PKG)

## Thread Sanitizer：跨執行緒的元件
test-tsan:
	swift test --package-path $(PKG) --sanitize=thread --filter 'RingBufferTests|PumpTests|JournalTests|LiveTranscript|CaptureMixer|LiveCaptionModel|EngineContract|TranscribeTranslateEngine|LiveRecording|SessionLock|RecordingWriteFailure|CaptureRestart|SourceSwitch|SampleRateConverter'

## 效能預算（release 模式、一次跑一個）。預算在 Benchmarks/perf-budgets.json
test-perf:
	swift test --package-path $(PKG) -c release --no-parallel --filter 'Perf'

## 8 小時長跑（release 模式）。會寫出約 1 GB 的暫存檔
test-soak:
	THUNDER_SOAK=1 swift test --package-path $(PKG) -c release --no-parallel --filter 'Soak'

## 發布前的完整檢查
check: build test test-tsan test-perf
	Scripts/check-no-dependencies.sh
	Scripts/list-tests.py --check

## 把 App 編成 build/ThunderFlow.app（不需要開 Xcode）
app:
	Scripts/build-app.sh

## 編好之後直接開啟
run: app
	open build/ThunderFlow.app

## iPhone 版（DESIGN.md 5.10 節）：編譯給模擬器，不需要簽章
phone:
	xcodebuild -project iOS/ThunderFlowPhone.xcodeproj -scheme ThunderFlowPhone -destination 'generic/platform=iOS Simulator' -derivedDataPath build/phone-dd -quiet build

## iPhone 版的自我檢查：在看不到的模擬器上用音檔跑一整場（會連線，30 秒約 US$0.01）
phone-selftest:
	Scripts/phone-selftest.sh build/phone-selftest

## 把 iPhone 版裝到接著的 iPhone（要先有 iOS/Local.xcconfig 的 DEVELOPMENT_TEAM，Scripts/phone-install.sh 的說明）
phone-install:
	Scripts/phone-install.sh

## iPhone 版上傳到 App Store Connect，給 TestFlight 用（要先在 App Store Connect 建好這個 App）
phone-testflight:
	Scripts/phone-testflight.sh

## 量測整個 App：啟動時間、閒置的 CPU 與記憶體、App 大小，和空白的 SwiftUI App 比較（約 3 分鐘，不花 API 費用）
measure-app:
	Scripts/measure-app.sh

## 量測錄音與即時翻譯中的 CPU：用音檔跑一場、顯示視窗（約 1.5 分鐘，花費不到 US$0.02）。加 ARGS=--hidden 隱藏執行
measure-recording:
	Scripts/measure-recording.sh $(ARGS)
