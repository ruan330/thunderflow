# ThunderFlow 開發規範

macOS 原生的即時翻譯與錄音 App。**設計與決策一律以 [DESIGN.md](DESIGN.md) 為準**，動工前先讀它。

## 指令

```sh
make build       # 編譯全部（含測試）
make test        # 每次提交都要跑
make test-tsan   # Thread Sanitizer（跨執行緒的元件）
make test-perf   # 效能預算（release 模式）
make test-soak   # 8 小時長跑（會寫出約 1 GB 的暫存檔）
```

所有邏輯都在 `Packages/ThunderKit`，用 `swift test` 就能驗證，不需要開 Xcode。
只跑部分測試：`swift test --package-path Packages/ThunderKit --filter RingBuffer`

## 測試先行（DESIGN.md 第 9 節）

1. 每個工作項目先提交**會失敗的測試**（`test:` 提交），審過之後才實作（`feat:` 提交）。
2. **不可以為了讓測試通過而修改測試。** 認為測試寫錯時：停下來說明理由，取得同意後用獨立的提交修改。
3. 測試只用公開介面（不用 `@testable import`），所以 release 模式也能跑。
4. 測試不可以卡住：等待一律設時限（`withDeadline`、`completesWithin`、`waitUntil`）。
   - async 的測試裡等待要用 `await waitUntil { … }`，不要用 `usleep`、semaphore 這類會占住執行緒的等待。被等待的工作和測試共用同一個執行緒池，核心數少的機器（CI 只有 3 核心）上會互相卡住。
   - 懷疑有這種問題時，用 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 make test` 把執行緒池限制成 1 條來檢查。
5. 測試名稱用繁體中文，直接寫出「什麼情況下應該怎樣」。
6. 效能預算就是測試：數值放在 `Benchmarks/perf-budgets.json`，不要寫死在測試裡，也不要為了通過而放寬。

## 不可以違反的規則

- **錄音路徑不等待任何東西**：`RecordingSession.process` 是同步的，不可以等待引擎、網路或 Swift concurrency。
- **即時音訊 callback 只做 memcpy**：不配置記憶體、不上鎖、不寫 log、不 `await`。
- **不加第三方套件**（`Scripts/check-no-dependencies.sh` 會擋）。
- **憑證只放 Keychain**：不寫進檔案、log、測試資料或提交紀錄。這個 repo 是公開的。
- **私人的錄音與逐字稿只放 `Benchmarks/private/`**（不進 git）。提交進 repo 的測試資料只用合成語音錄製；報告只寫統計數字，不引用錄音的內容。
- **檔案就是資料**：不引入資料庫；`session.json` 與日誌的格式變更要同步更新 DESIGN.md 與 `schemaVersion`。
- 介面文字、註解與文件使用繁體中文（台灣用語）。

## 實驗工具

`Tools/thunderbench` 是探索 API 用的命令列工具與分析腳本（獨立的小 package，不屬於 ThunderKit），會產生 API 費用。
實驗報告在 `Benchmarks/results/`，錄下來的 API 事件在 `Benchmarks/fixtures/`（給引擎測試重播）。

## 目前進度

見 DESIGN.md 第 12.1 節的里程碑表。
