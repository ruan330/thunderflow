# ThunderFlow 開發指令。所有邏輯都在 Packages/ThunderKit，不需要開 Xcode 就能建置與測試。

PKG := Packages/ThunderKit

.PHONY: build test test-tsan test-perf test-soak check

## 編譯全部（含測試）
build:
	swift build --package-path $(PKG) --build-tests

## 每次提交都要跑：單元、整合、當機安全、30 分鐘記憶體測試
test:
	swift test --package-path $(PKG)

## Thread Sanitizer：跨執行緒的元件
test-tsan:
	swift test --package-path $(PKG) --sanitize=thread --filter 'RingBufferTests|PumpTests|JournalTests'

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
