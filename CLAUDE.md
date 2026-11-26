# ThunderFlow 開發規範

macOS 原生的即時翻譯與錄音 App。**設計與決策一律以 [DESIGN.md](DESIGN.md) 為準**，動工前先讀它。

## 指令

```sh
make build       # 編譯全部（含測試）
make test        # 每次提交都要跑
make test-tsan   # Thread Sanitizer（跨執行緒的元件）
make test-perf   # 效能預算（release 模式）
make test-soak   # 8 小時長跑（會寫出約 1 GB 的暫存檔）
make app         # 打包成 build/ThunderFlow.app（ad-hoc 簽章）
make run         # 打包之後開啟
make measure-app        # 啟動、閒置、App 大小的預算（約 3 分鐘，不花 API 費用）
make measure-recording  # 錄音中 CPU 的預算（會顯示視窗約 1 分鐘，花費不到 US$0.02；ARGS=--hidden 隱藏執行）
make phone       # iPhone 版（iOS/）編譯給模擬器，不需要簽章
make phone-selftest     # iPhone 版在看不到的模擬器上用音檔跑一整場（會連線，30 秒約 US$0.01）
make phone-install      # iPhone 版（Release）裝到用線接著的 iPhone：要先有 iOS/Local.xcconfig 的 DEVELOPMENT_TEAM
```

所有邏輯都在 `Packages/ThunderKit`，用 `swift test` 就能驗證，不需要開 Xcode。
畫面在 `App/`（只放 SwiftUI／AppKit 與組裝，不放判斷）。
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
- **打包不自動挑選鑰匙圈裡的簽章憑證**：用失效的憑證簽章，macOS 會把 App 當成惡意軟體丟進垃圾桶。預設 ad-hoc；要用憑證就明確指定 `THUNDERFLOW_SIGN_IDENTITY`。
- **憑證只放 Keychain**：不寫進檔案、log、測試資料或提交紀錄。這個 repo 是公開的。
- **私人的錄音與逐字稿只放 `Benchmarks/private/`**（不進 git）。提交進 repo 的測試資料只用合成語音錄製；報告只寫統計數字，不引用錄音的內容。
- **檔案就是資料**：不引入資料庫；`session.json` 與日誌的格式變更要同步更新 DESIGN.md 與 `schemaVersion`。
- 介面文字、註解與文件使用繁體中文（台灣用語）。

## 實驗工具

`Tools/thunderbench` 是探索 API 用的命令列工具與分析腳本（獨立的小 package，不屬於 ThunderKit），會產生 API 費用。
`thunderbench live <音檔.wav>` 用正式的引擎處理一個音檔，印出每個字幕事件：改動引擎之後用它對真正的服務確認一次。
App 有隱藏的自我檢查：用音檔跑完一整場並把畫面存成圖檔。一律隱藏執行、用暫存的工作目錄與 Library（不和使用者開著的 App 共用），Key 經由 FIFO 從標準輸入傳入（不碰 App 的鑰匙圈項目，不會跳出授權視窗，Key 也不落地）：

```sh
S=<暫存資料夾>; mkdir -p $S; mkfifo -m 600 $S/key
security find-generic-password -a "$USER" -s thunderflow-openai-dev -w > $S/key &
open -W -n -g -j build/ThunderFlow.app --stdin $S/key --stdout $S/out --args -ApplePersistenceIgnoreState YES -apiKeyFromStdin YES \
  -selfTestFile "$PWD/Benchmarks/data/keynote.wav" -selfTestSeconds 30 -selfTestSnapshot $S/shot -selfTestQuit YES \
  -workingPath $S/working -libraryPath $S/lib
```

`Benchmarks/data/` 的音檔由 `thunderbench synth` 產生（不進 git）。這些參數只從啟動參數讀，不要用 `defaults write` 寫進去。
`-ApplePersistenceIgnoreState YES` 讓測試用的實例不恢復上次的視窗狀態：沒有它時，視窗可能不出現，自我檢查就永遠不會開始，也沒有任何輸出。

實機檢查系統音訊的擷取（改動擷取之後要跑；不連線、不需要 Key、不建立場次）：

```sh
open -W -n -g -j build/ThunderFlow.app --stdout $S/out --args -ApplePersistenceIgnoreState YES -diagnoseCapture YES -diagnoseSeconds 12 -selfTestQuit YES \
  -workingPath $S/working -libraryPath $S/lib
```

最後一行的 `ratio` 是收到的音訊長度除以實際經過的時間：沒有任何 App 出聲時也要接近 1。重新打包之後第一次執行會跳出「錄製系統音訊」的授權視窗，要請負責人按「允許」。用真的系統音訊跑一整場（會連線、花費很少）：把上面自我檢查的 `-selfTestFile …` 換成 `-selfTestSource system`（麥克風是 `-selfTestSource microphone`）。
改動字幕區的外觀之後，用 `-selfTestCaptions $S/captions -displayMode chinese`（或 `english`、`bilingual`）把一組固定的字幕畫成 `$S/captions.png`，和改之前的圖比對：不錄音、不連線、不需要 Key，顯示模式只從啟動參數讀，不會改到使用者的設定。
加上 `-reportPerf YES` 會在每一場印出 `perf.startToCapture.ms`（按下開始到第一個樣本）與 `perf.mainThreadHitch.ms`（錄音中主執行緒最長的卡頓）。隱藏執行時畫面不會真的畫，卡頓要在看得到的視窗量。
實驗報告在 `Benchmarks/results/`，錄下來的 API 事件在 `Benchmarks/fixtures/`（給引擎測試重播）。

iPhone 版（D36）：`make phone-selftest` 在看不到的模擬器上跑一整場，交到 App 自己資料夾裡的收件匣，跑完複製到 `build/phone-selftest/inbox`。
要檢查 Mac 收得進來：把那個收件匣複製一份、`chmod -R a-w`（收好之後移不走，不會把東西丟進使用者的垃圾桶），
再用隱藏的 Mac 版加上 `-inboxPath <那一份> -hasKey NO`（和 `-workingPath`、`-libraryPath` 一起；有 `-workingPath` 的實例不看設定裡的收件匣，
除非也給 `-inboxPath`）開一個實例，等 Library 出現 `complete` 的場次之後結束它。

## 目前進度

見 DESIGN.md 第 12.1 節的里程碑表。

**接手之前先讀 [HANDOVER.md](HANDOVER.md)**（2026-11-21 的交接：哪些驗證過、已知的問題與位置、建議的工作順序、操作上容易出錯的地方）。裡面的項目全部處理完之後，刪掉那個檔案與這一段。
