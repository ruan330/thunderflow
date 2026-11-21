# ThunderFlow 交接文件

> 日期：2026-11-21　｜　交接者：Claude Fable 5.2　｜　接手者：下一位在這個 repo 工作的模型（預定是 Claude Opus）
> 分支：`m2/assemble`（只在本機，沒有推上 GitHub，也沒有合併進 `main`）

## 怎麼用這份文件

- 設計與決策看 [DESIGN.md](DESIGN.md)，開發規則看 [CLAUDE.md](CLAUDE.md)。這份文件只寫那兩份沒有的：現在實際做到哪裡、哪些驗證過、哪些沒有、接下來建議做什麼、哪裡容易出錯。
- 每個問題都標了查證的程度：
  - **已實測**：我實際跑過並看到結果。
  - **讀程式碼確認**：每一步都在程式碼裡看到了，但沒有實際觸發過。
  - **推測**：合理的懷疑，動手之前先自己確認。
- 做完一項就把它從這份文件刪掉；需要長期保留的結論移進 DESIGN.md。全部處理完就刪掉這個檔案。

## 1. 一分鐘版本

1. **開發版做出來了**（`make run`）。即時翻譯、錄音、中英逐字稿、摘要、過去錄音的瀏覽都跑得通，用音檔當來源驗證過完整的一場。
2. **最大的未知：麥克風與系統音訊從來沒有在真的裝置上跑過。** 到交接為止，沒有任何人在 App 裡按過「開始錄音」。
3. **最嚴重的已知問題：錄音途中再開一個視窗（或第二個 App 實體），正在錄的那一場會被當成「上次中斷的場次」拿去收尾，之後的聲音靜靜地遺失。** 見第 4 節 P1。先修這個。
4. **「快與輕」只證明了一半**：23 項效能預算裡有 13 項沒有測試（第 5 節階段 C）。
5. **v1 還缺的功能**：精修中文、首次啟動引導、靜音不送、裝置消失與睡眠的處理、逐字稿全文搜尋等（第 6 節）。
6. **這個分支沒有第二個人看過**：22 個提交、約 11,000 行，M2–M4 新增的 173 個測試也沒有先給專案負責人審就實作了。

## 2. 現在的狀態

| 項目 | 狀態 |
|---|---|
| 分支 | `m2/assemble` = `main`（0344b79，和 `origin/main` 相同）加上 22 個提交與這份文件的提交。沒有推送 |
| 測試 | 交接時在 a6f775c 重跑，全部通過：`make test` 338 個（6 個測試 target）、`make test-tsan` 48 個、`make test-perf` 7 個。8 小時長跑（`make test-soak`）上一次是 M1 完成時跑的 |
| App | `build/ThunderFlow.app`，2.9 MB，ad-hoc 簽章（`build/` 不進 git） |
| 里程碑 | M0、M1 完成；M2、M3、M4 進行中（DESIGN.md 12.1 節） |
| 環境 | 開發機：MacBook Pro M1 Max、macOS 27.0.1、Xcode 27.2、Swift 6.4.2。CI：`macos-26`、Swift 6.3.3，只有 3 個核心 |
| 費用 | 到目前為止的 API 實驗約 US$4–5（依公告價格估算）；組裝這個開發版的那一輪約 US$0.03–0.05 |

### 程式碼在哪裡

| 位置 | 內容 | 測試 |
|---|---|---|
| `Packages/ThunderKit/Sources/ThunderCore` | 事件模型、日誌、場次資料夾與 `session.json`、逐字稿段落與 Markdown、摘要的結構、文字模型的介面、Keychain、簡體字檢查 | 有 |
| `…/ThunderAudio` | RingBuffer、Pump、CAF 分段錄音、轉成 24 kHz PCM16、`CaptureMixer`（即時 callback）、`AudioCapture`（麥克風／系統音訊／音檔）、`RecordingMerger`（合併成 m4a） | 有；`AudioCapture` 碰硬體的部分沒有 |
| `…/ThunderSession` | `RecordingSession`（錄音路徑）、`LiveRecording`（把收音、錄音、引擎組起來）、`SessionRecovery`、`SessionFinalizer`、`SessionLibrary` | 有 |
| `…/ThunderEngines` | 四個不碰網路的狀態機（`PauseDetector`、`Segmenter`、`TranscriptionLink`、`TranslationPlanner`），外殼 `TranscribeTranslateEngine`，`OpenAITextModel`、`RealtimeSocket` | 有（用錄下來的事件重播） |
| `…/ThunderUI` | 只有 `CaptionBoard` 與 `LiveCaptionModel` | 有 |
| `…/ThunderTestKit` | 假引擎、假文字模型、重播用的假連線 | — |
| `App/Sources/ThunderFlow` | 6 個檔案、1,641 行：`AppModel`（整個 App 的狀態）、三個頁面、浮動字幕、設定 | **完全沒有** |
| `Tools/thunderbench` | 實驗工具。`thunderbench live <wav>` 用正式的引擎對真正的服務跑一個音檔 | — |

## 3. 驗證過的，和沒驗證過的

### 驗證過

| 項目 | 怎麼驗證的 | 限制 |
|---|---|---|
| 錄音核心（M1） | 測試、Thread Sanitizer、效能預算、8 小時長跑 | 來源是合成的樣本，不是真的裝置 |
| 引擎對真正的服務 | `thunderbench live` 跑 40 秒合成語音：9 段全部有台灣繁體的定稿，沒有簡體字 | 合成語音；結果沒有存成報告 |
| 整個 App 跑完一場 | App 隱藏的自我檢查，用音檔當來源錄 45 秒：畫面上有字幕（看過截圖），產生了 `recording.m4a`（45.29 秒，和 `session.json` 的長度一致）、`transcript.md`、`summary.md`，場次自動命名，完整性計數全部是 0 | 來源是音檔，沒有經過 Core Audio 的裝置 |
| 當機復原 | 一場錄到一半 App 被結束，下次啟動時自動復原並做完結束處理 | 只發生過一次，是意外，不是刻意設計的測試 |
| 閒置時的負擔（非正式） | App 開著 15 分鐘沒有操作，用 `top` 看 9 秒：CPU 0.0%、記憶體約 60 MB、4 條執行緒 | 不是 DESIGN.md 9.8 節規定的量法（要和空白 SwiftUI App 比） |

### 沒驗證過

| 項目 | 說明 |
|---|---|
| **麥克風收音** | 只測了 callback 的邏輯（`CaptureMixer`）。HAL 的部分沒有執行過 |
| **系統音訊收音** | 同上。Process Tap 與 aggregate device 的程式碼是照文件寫的，沒有執行過 |
| 正式引擎在真實語音上的延遲與品質 | 真實錄音只用實驗腳本（M0b）和元件（停頓偵測、切段）驗證過，沒有用 `thunderbench live` 跑過 |
| 45 分鐘換線、60 分鐘連線上限 | 換線與重新連線只用假連線測過，沒有對真正的服務跑過一小時以上 |
| 純轉錄連線遇到無效的 Key | 只用假連線測過（DESIGN.md 12.3 節） |
| 一小時以上的場次在畫面上的表現 | 沒有跑過。字幕清單的成本會隨場次變長（P6） |
| 清單、詳細頁、設定頁、浮動字幕 | 只看過三張截圖（即時翻譯頁、詳細頁、設定頁）。沒有自動測試，也沒有人實際操作過 |
| 權限被拒、裝置拔掉、睡眠、磁碟滿 | 都沒有試過 |

## 4. 已知的問題

依嚴重程度排列。位置是交接時（a6f775c）的行號。

### P1　錄音途中，正在錄的場次會被當成中斷的場次拿去收尾（會遺失錄音）

- **查證**：讀程式碼確認了每一步。我試著用兩個隱藏的 App 實體重現，但測試實體卡在鑰匙圈的授權視窗（見第 8 節），沒有重現成功。
- **經過**：
  1. `RecordingSession` 一建立就把 `session.json` 寫成 `recording`。
  2. [`AppModel.didAppear()`](App/Sources/ThunderFlow/AppModel.swift#L74) 由 `RootView` 的 `.task` 呼叫（[ThunderFlowApp.swift:50](App/Sources/ThunderFlow/ThunderFlowApp.swift#L50)），所以每開一個視窗就執行一次，不是每個程序一次。
  3. `didAppear()` 會呼叫 [`resumeUnfinished()`](App/Sources/ThunderFlow/AppModel.swift#L306)：把工作目錄裡所有狀態是 `recording` 的場次復原（[`SessionRecovery.findInterrupted`](Packages/ThunderKit/Sources/ThunderSession/SessionRecovery.swift#L29) 只看狀態，分不出「正在錄」和「上次中斷」），再對它們執行結束處理。
  4. 結束處理會把 CAF 分段合併成 m4a、**刪掉 CAF 分段**（[SessionFinalizer.swift:189](Packages/ThunderKit/Sources/ThunderSession/SessionFinalizer.swift#L189)）、把資料夾搬進 Library。
  5. 仍在進行的錄音繼續寫進已經被刪除或搬走的檔案；下一個分段建立失敗時錯誤被吞掉（P2）。那之後的聲音都沒有留下，畫面上沒有任何提示。
- **會觸發的操作**（推測，還沒實機確認）：
  - 錄音中按 ⌘N。`WindowGroup` 預設有「新增視窗 ⌘N」；錄音中「開始錄音」的按鈕不在畫面上，所以 ⌘N 會開出第二個視窗。
  - 錄音中關掉主視窗（例如只留浮動字幕），再從 Dock 點開。
  - 同時執行第二個 App 實體。自我檢查用的 `open -n` 就是這樣，而且工作目錄不能用參數換掉。
- **建議的修法**：
  1. 錄音中持有場次資料夾裡一個檔案的 `flock`；復原時先試著取得鎖，拿不到就跳過。程序結束時核心會自動釋放鎖，所以真正中斷的場次仍然找得到，也同時擋住兩個實體。先在 `ThunderSessionTests` 寫測試：「正在錄的場次不會被回報成中斷」、「錄音的程序被結束之後才會被回報」。
  2. 啟動後的工作每個程序只做一次。主視窗改成單一視窗（`Window`，不是 `WindowGroup`），同時解決 ⌘N 的衝突。

### P2　錄音檔寫入失敗時沒有任何提示

- **查證**：讀程式碼確認，沒有實際觸發。
- [`LiveRecording.swift:83`](Packages/ThunderKit/Sources/ThunderSession/LiveRecording.swift#L83) 用 `try?` 呼叫 `session.process`；[`RecordingSession.process`](Packages/ThunderKit/Sources/ThunderSession/RecordingSession.swift#L160) 在錄音檔寫不進去時會丟出錯誤。錯誤被丟掉之後，沒有計數、沒有日誌、沒有橫幅：聲音沒有被錄下來，畫面上只看得到時間停住。
- DESIGN.md 2.1 節要求磁碟空間不足時「安全地收尾」，並且每一場都要記錄有沒有掉音。目前只在開始時檢查剩餘空間，錄音中不檢查。

### P3　裝置消失、預設裝置改變、睡眠與喚醒都沒有處理

- **查證**：已實測（整個專案搜尋不到任何 Core Audio 的屬性監聽，也沒有睡眠與喚醒的通知）。
- 目前只有一個檢查：3 秒沒有收到 callback 就顯示橫幅（[AppModel.swift:209](App/Sources/ThunderFlow/AppModel.swift#L209)）。不會自動換裝置，也不會重新開始收音。
- 系統音訊的 aggregate device 以開始時的預設輸出裝置當時脈。錄音中接上或拔掉耳機會發生什麼，還不知道。

### P4　收音的程式碼有幾個實機才能確認的疑點

位置都在 [AudioCapture.swift](Packages/ThunderKit/Sources/ThunderAudio/AudioCapture.swift)。

| 疑點 | 查證 | 說明 |
|---|---|---|
| 輸出裝置的麥克風被混進系統音訊 | 讀程式碼確認 | aggregate device 把預設輸出裝置放進子裝置清單（215–226 行），`CaptureMixer` 把收到的所有聲道平均成單聲道。輸出裝置自己有輸入聲道時（USB 耳機麥克風），它的麥克風會被混進來。可以試只放擷取點、不放子裝置 |
| 多聲道的錄音介面音量變小 | 讀程式碼確認 | 同一個平均：8 聲道的介面只接一支麥克風時，音量只剩八分之一 |
| 取樣率可能和實際不符 | 推測 | 回傳的是擷取點格式的取樣率（237 行）。如果 aggregate device 實際用另一個取樣率在跑，錄音的速度與音高會不對。嗶聲測試（DESIGN.md 9.11 節）看得出來 |
| 沒有排除 ThunderFlow 自己的聲音 | 推測 | 程序還沒有音訊物件時 `ownProcessObject()` 回傳 nil（206、240 行），擷取點就不排除任何程序。錄系統音訊時在詳細頁播放舊錄音，可能會被錄進去 |
| 錄音中取樣率改變 | 讀程式碼確認 | 取樣率只在開始時讀一次，之後不監聽 |

### P5　按下開始時，會等待的工作在主執行緒上執行

- **查證**：讀鑰匙圈會卡住主執行緒是已實測（用 `sample` 看到主執行緒停在 `SecItemCopyMatching`）；其餘讀程式碼確認，沒有量過時間。
- [`AppModel.start()`](App/Sources/ThunderFlow/AppModel.swift#L87) 在主執行緒上讀鑰匙圈（90 行）、開始收音（137 行，包含建立擷取點與啟動裝置）。鑰匙圈跳出授權視窗時，整個畫面會凍結到使用者回答為止。
- [`refreshDevices()`](App/Sources/ThunderFlow/AppModel.swift#L81) 在第一個畫面出現之後、在主執行緒上第一次碰 Core Audio。
- 對應的預算：按下開始到開始收音 ≤ 300 ms、主執行緒最長的卡頓 ≤ 100 ms。兩項都還沒有量。

### P6　字幕清單的成本隨場次變長

- **查證**：讀程式碼確認，沒有量過。先量再改。
- [`LiveCaptionModel.flush()`](Packages/ThunderKit/Sources/ThunderUI/LiveCaptionModel.swift#L56) 每次更新先複製整個 `CaptionBoard` 再比較新舊；有段落確定或譯文回來時，這兩步都和已經累積的行數成正比。
- [`CaptionsView`](App/Sources/ThunderFlow/LiveView.swift#L163) 每次更新都把全部的行交給中文、英文兩區的 `ForEach`（178、189 行）。8 小時的場次大約 6,500 行。
- DESIGN.md 9.8 節寫的是「即時字幕只重畫最後幾行」，對應的預算 `ui.eventCostGrowth.ratio.max`（第 8 小時的成本不超過第 1 分鐘的 1.5 倍）沒有測試。

### P7　畫面的狀態與判斷放在沒有測試的地方

- [AppModel.swift](App/Sources/ThunderFlow/AppModel.swift) 有 374 行，裡面有開始與停止的狀態轉換、沒有聲音的判斷門檻、結束處理與復原的安排。CLAUDE.md 規定 `App/` 不放判斷，這裡違反了。P1 就出在這裡。
- 另外兩個讀程式碼確認的小問題：
  - `start()` 在等待麥克風權限（97 行）之後才把狀態改成 `starting`（105 行）。授權視窗還開著時再按一次開始，會建立兩場錄音，第一場沒有辦法停止。
  - `stop()` 失敗時（162–164 行）場次要等下次啟動才會復原。

### P8　其他比較小的

| 問題 | 查證 | 位置與說明 |
|---|---|---|
| 畫面沒有用引擎回報的數字 | 讀程式碼確認 | `LiveCaptionModel` 收了 `billedSeconds` 與 `gapSeconds`，但畫面沒有顯示。費用是用錄音時間乘上寫死的單價（[AppSettings.swift:112](App/Sources/ThunderFlow/AppSettings.swift#L112)） |
| 定稿不是邊收邊顯示 | 讀程式碼確認 | 見第 7 節的第 1 個方向 |
| 浮動字幕缺選項 | 讀程式碼確認 | 字級寫死 26，沒有滑鼠穿透、透明度、螢幕分享時隱藏（DESIGN.md 4.4 節） |
| 詳細頁在主執行緒上讀檔 | 讀程式碼確認 | [LibraryView.swift:128](App/Sources/ThunderFlow/LibraryView.swift#L128)。一般大小沒有問題，但「打開 8 小時的場次 ≤ 100 ms」沒有測試 |
| 斷線那一瞬間正在送的音訊會遺失，沒有記成缺口 | 已記在 DESIGN.md 12.3 節 | 約 0.2–0.4 秒 |
| `session.json` 有好幾個地方會改寫 | 背景 agent 回報，未查證 | 結束處理、停止錄音、復原、摘要都是「讀出、修改、寫回」，彼此沒有協調 |
| 合併錄音時用第一個分段的取樣率 | 背景 agent 回報，未查證 | 錄音中取樣率改變時會出錯（和 P4 最後一項有關） |
| Library 在另一個磁碟時的搬移 | 背景 agent 回報，未查證 | 跨磁碟的路徑沒有測試 |
| 測試數量對不上 | 已實測 | `make test` 執行 338 個，TESTS.md 寫 334 個。背景 agent 回報 `Scripts/list-tests.py` 遇到 tuple 參數會算錯，還沒查是哪 4 個 |

## 5. 建議的工作順序

原則照 DESIGN.md 2.3 節：先量測再決定、測試先行。**沒有量測結果或會失敗的測試，就不要動手優化。**

### 階段 A　先確保不會遺失錄音

1. 修 P1（測試先行，修法見上）。
2. 修 P2：寫入失敗要計入完整性計數、記進日誌，並讓畫面知道。
3. 修 P7 的兩個小問題。
4. 讓 App 自己把 Key 存進鑰匙圈（見第 8 節「鑰匙圈」），自我檢查才能無人值守地執行。

完成條件：新的測試先失敗後通過；`make test`、`make test-tsan`、`make test-perf` 通過；用自我檢查重跑一次完整的場次。

### 階段 B　第一次實機驗證（需要專案負責人在電腦前，約 20 分鐘，API 費用不到 US$0.1）

授權視窗只能由人來按，所以這一步要和負責人一起做。

1. 麥克風錄 2 分鐘，系統音訊錄 2 分鐘（播放一段英文演講）。
2. 每一場檢查：`session.json` 的完整性計數是不是 0；`recording.m4a` 的長度和畫面上的時間是否一致；聲音的速度與音高是否正常。
3. 嗶聲測試（DESIGN.md 9.11 節）：用另一個程式播放每秒嗶一聲的音檔，錄下來之後檢查相鄰兩聲的間隔。
4. 逐項確認 P4 的疑點，並試一次錄音中拔掉耳機。

完成條件：DESIGN.md 9.12 節的清單至少完成「內建麥克風」與「戴著耳機播放 YouTube」兩項，結果寫回 DESIGN.md。

### 階段 C　把「快與輕」變成測試

13 項沒有測試的預算（`Benchmarks/perf-budgets.json`）：

| 做法 | 預算 |
|---|---|
| 直接在 package 裡寫測試 | `ui.eventCostGrowth`、`library.scan500`、`library.openSession8h`、`session.stopToTranscript`、`finalize.audioPerRecordedHour`、`library.search500`（要先有全文搜尋） |
| 需要量測整個 App 的腳本（DESIGN.md 9.8 節的做法：App 回報啟動到第一個畫面的時間，連續啟動 20 次取中位數，和空白 SwiftUI App 比） | `app.launch.firstFrame`、`app.launch.vsEmptyShell`、`app.idle.cpuPercent`、`app.idle.footprintOverEmptyShell`、`app.recording.cpuPercent`、`app.bundleSize` |
| 只能實機量 | `session.startToCapture`、`ui.mainThreadHitch` |

量出來之後再處理 P5 與 P6。完成條件：每一項預算都有對應的測試或腳本，數字寫進 DESIGN.md 9.8 節的「依據」欄。

### 階段 D　把畫面的狀態搬進有測試的地方（P7）

把 `AppModel` 裡的判斷移到 `ThunderUI` 或 `ThunderSession`，用公開介面測試；`App/` 只留畫面與組裝。之後改畫面才不會再出現 P1 這種問題。

### 階段 E　補齊 v1 的功能

見第 6 節。建議的順序：裝置消失與睡眠（P3）→ 靜音不送 → 精修中文 → 逐字稿全文搜尋 → 首次啟動引導 → 浮動字幕的選項 → 超過 3 小時的分段摘要。

### 階段 F　用真實語音把體驗調到位（需要負責人的判斷，會花 API 費用）

1. 用 `thunderbench live` 跑 `Benchmarks/private/recordings/` 裡的真實錄音，和 DESIGN.md 9.10 節的門檻比。
2. 請負責人看實際的畫面，決定暫定譯文怎麼顯示（DESIGN.md 的 D21）。
3. 一次 60 分鐘以上的實測（約 US$1.2），確認換線。
4. 第 7 節的幾個方向，各自量過再決定要不要做。

### 階段 G　發布（M5）

簽章與公證（等負責人決定 Developer ID）、README 的截圖、DESIGN.md 9.12 節的實機清單、三場 45 分鐘以上的實地使用。

## 6. v1 還沒做的功能

對照 DESIGN.md 2.1 節。

| 功能 | 章節 | 現況 |
|---|---|---|
| 精修中文（補上沒翻到的段、統一術語、整理成段落） | 5.7.2 | 沒做。逐字稿用的是當場的中文定稿；沒翻到的段留空 |
| 首次啟動引導（輸入 Key、授權並測試系統音訊、確認資料夾） | 4.2 | 沒做。現在是按開始時才檢查，缺 Key 就跳到設定頁 |
| 靜音超過 2 秒不送 | 5.6、12.3 | 沒做。靜音是否計費還不知道 |
| 裝置消失、睡眠與喚醒 | 2.1、9.12 | 沒做（P3） |
| 逐字稿的全文搜尋 | 4.5、4.6 | 沒做。清單只搜尋標題、一句話總結與活動名稱。先前量過：直接掃描 mmap 的檔案，500 場約 0.14 秒 |
| 超過 3 小時的場次分段摘要 | 5.8 | 沒做 |
| 浮動字幕的滑鼠穿透、透明度、螢幕分享時隱藏 | 4.4 | 沒做 |
| 憑證不外洩的掃描（不變條件 5） | 9.5 | 沒做 |
| Library 在 iCloud 同步的資料夾時提醒 | 12.3 | 沒做 |
| 用 os_signpost 量「收到事件到顯示在畫面上」 | 9.10 | 沒做 |

已經有的：暫停與繼續、標記重點、關鍵詞與場次資訊、雙語／只看中文／只看英文、字級、預估費用、Key 的測試／顯示／刪除、在 Finder 中顯示、刪除（移到垃圾桶）、重新產生摘要、播放器（速度、前後 15 秒、點段落或章節跳轉）、完整性的說明、當機復原。

## 7. 可以讓它更快、更好的方向

這些都是還沒量過的想法，每一項都要先量再決定。

1. **定稿邊收邊顯示。** 現在定稿要等整句翻完才出現：[`TranslationPlanner.progress`](Packages/ThunderKit/Sources/ThunderEngines/TranslationPlanner.swift#L184) 對定稿的請求只記下「有收到輸出」。`CaptionBoard` 已經能在確定的那一行顯示暫定文字（[CaptionBoard.swift:52](Packages/ThunderKit/Sources/ThunderUI/CaptionBoard.swift#L52)），所以把定稿請求的進度當成那一行的暫定譯文送出，畫面就會提早出字。先前的實驗量到第一個字約 0.65–0.83 秒、整句約 1.0–1.3 秒，可能提早 0.3–0.5 秒。代價是那一行會先以淡色逐字出現再變成正式的顏色，要請負責人看過。
2. **預先建立文字模型的連線。** 每一場第一個翻譯請求要多付一次連線建立的時間。先用 `thunderbench live` 比較第一段和其餘各段的延遲，確認差多少。
3. **在真實語音上校正門檻。** `provisionalWords`、`provisionalInterval`、`contextSegments`、轉錄的 `delay`（`low` 或 `medium`）都是設定值，目前的數字來自一段錄音。
4. **量正式引擎的暫定譯文改寫率。** 實驗腳本在真實語音上約七成的更新會改到已顯示的字；現在的規則（一次只送一個請求，第一個邊收邊顯示，之後整句回來才取代）還沒有量過。
5. **使用者打開即時翻譯頁時先建立轉錄連線。** M0 在即時翻譯連線上量過：連線約 0.9 秒，建立後閒置 60 秒沒有問題；純轉錄連線還沒有量。可以縮短按下開始到第一行字幕的時間，但要確認閒置的連線是否計費。
6. **畫面只保留最近的行。** 配合 P6，量過之後再決定。

## 8. 操作上容易出錯的地方

### 簽章

- `Scripts/build-app.sh` 預設用 ad-hoc 簽章。**不要讓腳本自動挑選鑰匙圈裡的憑證**：這台 Mac 的鑰匙圈有一張被系統拒絕的「Apple Development」憑證，用它簽的 App 一執行就被終止，macOS 會顯示「包含惡意軟體」並把 App 丟進垃圾桶。`codesign --verify` 與 `security find-identity -v` 都說它有效，所以看不出來。
- ad-hoc 簽章的代價：每次重新編譯，程式的雜湊值就不同，鑰匙圈會重新詢問；麥克風與系統音訊的授權預期也會重新詢問（這一項還沒有實際遇到，因為從來沒有授權過）。
- 有一張有效的開發者憑證（用 `THUNDERFLOW_SIGN_IDENTITY` 指定）可以一次解決這兩件事。要不要更新憑證，等負責人決定（第 10 節）。

### 鑰匙圈

- 開發用的 Key 在鑰匙圈項目 `thunderflow-openai-dev`（帳號 `$USER`）。只在執行時讀取：`security find-generic-password -a "$USER" -s thunderflow-openai-dev -w`。不要印出來，不要放進指令的參數、檔案、log 或提交。
- App 讀的是它自己的項目：service 是 Bundle ID `io.github.ruan330.thunderflow`，帳號 `openai-api-key`。我把開發用的 Key 複製了一份到這個項目，負責人知道這件事；設定頁可以刪除。
- **已實測：用 `security add-generic-password -T <App>` 建立的項目，App 讀取時仍然會跳出授權視窗。** 交接當天試了兩次（原本的項目，以及刪掉重建之後），App 都卡在讀取。先前我以為「每次重新編譯之後重建項目就不會問」，這個說法不成立；先前的自我檢查為什麼跑得過，我沒有查出來。
- 所以目前的狀況是：這個版本第一次按「開始錄音」時，會跳出鑰匙圈的授權視窗，而且視窗出現時畫面會凍結（P5）。輸入 Mac 的登入密碼並按「永遠允許」之後，這個版本就不會再問。
- 建議的做法（階段 A 第 4 項）：加一個只在命令列使用的模式，從標準輸入讀 Key、由 App 自己存進鑰匙圈然後結束，寫法比照現有的 `--version`。App 自己建立的項目，同一個版本讀取時不會詢問。這是推測，做完要確認。

### 自我檢查

```sh
open -W -n -g -j build/ThunderFlow.app --args \
  -selfTestFile "$PWD/Benchmarks/data/keynote.wav" -selfTestSeconds 30 \
  -selfTestSnapshot <暫存資料夾>/shot -selfTestQuit YES -libraryPath <暫存資料夾>/lib
```

- `Benchmarks/data/` 不進 git，音檔由 `thunderbench synth` 從 `Benchmarks/synthetic/` 產生。
- 一定要隱藏執行（`-g -j`）並指定暫存的 `-libraryPath`。看得到的視窗會被點到，測試的場次也不該出現在負責人的「文件」資料夾。
- **工作目錄不能用參數換掉**，固定在 `~/Library/Application Support/ThunderFlow/Working`，和負責人開著的 App 共用。P1 修好之前，先確認那個資料夾是空的、沒有人在錄音，才能執行。
- 會讀鑰匙圈。上面的問題解決之前，它會卡在授權視窗（視窗會出現在負責人的螢幕上）。卡住時用 `pkill -f -- "-selfTestFile"` 結束它。
- 這些參數是從 UserDefaults 讀的，不要用 `defaults write` 寫進去，否則每次啟動都會執行。

### 測試與提交

- 現有的測試、測試工具與預算是鎖住的：認為測試寫錯時，停下來說明理由，取得負責人同意，用獨立的提交修改。到目前為止同意過兩次（a41efd0、efcfe9b）。
- 新功能先提交會失敗的測試（`test:`），再提交實作（`feat:`）。會失敗的那個提交必須能編譯、不能當掉也不能卡住：實作先放只有介面的空殼；測試裡不要直接用索引取陣列的元素，用 `#require`。
- Swift Testing 遇過的限制：`#require` 裡面不能再包 `#require`；`#expect(x.allSatisfy(\.p))` 要改成 closure；`@MainActor` 的測試裡等待要自己寫輪詢（`Task.sleep`），不能直接用測試工具的 `waitUntil`。
- 不改寫已經推送的歷史，不用 `git add -A`。`main` 有推送或開 PR 時 CI 會執行（repo 是公開的，CI 免費）。
- 私人的錄音與逐字稿只放 `Benchmarks/private/`；報告只寫統計數字。

### 其他

- 搜尋時排除 `.build`（`App/.build`、`Tools/thunderbench/.build`、`Packages/ThunderKit/.build` 都很大）。我交接當天用 `grep -r` 掃到它們，卡了兩分鐘。
- 編譯的輸出一律先過濾（`tail`、`cut`、`grep`）再看，完整的輸出非常長。
- `/bin/sh` 的腳本裡，變數後面緊接全形標點時要寫成 `${變數}`；zsh 遇到沒有符合的萬用字元會直接中止。
- 負責人的用量有上限，先前撞過一次（同時跑背景 agent，加上很長的對話）。可以分開的工作交給 subagent，輸出保持精簡。
- 每次對真正的服務執行都要花錢，回報時附上花費。超過一美元的實驗先問。
- 留下來的分支與 worktree：`m0/spike`、`m1/recording-core`、`m1/implementation`、兩個 `worktree-agent-…`，以及 `.claude/worktrees/` 底下的兩個資料夾。內容都已經在 `m2/assemble` 裡，我沒有刪。

## 9. 量測的基準

改善要和這些數字比。

| 指標 | 數值 | 條件 |
|---|---|---|
| 定稿延遲 | 中位數 1.09 秒、P95 2.08 秒 | 正式引擎、40 秒合成語音、9 段。從英文確定算起，不是從講者說完算起 |
| 第一個中文字 | 1.63 秒 | 同上。從該段第一個英文字出現算起 |
| 真實語音（實驗腳本，不是正式引擎） | 英文確定 0.72 秒、定稿 1.76 秒（P95 2.56）、第一個中文字 2.27 秒 | 一段 33 分鐘的現場收音，見 `Benchmarks/results/m0b-report.md` |
| 費用 | 約 US$1.2／小時 | M0b 的估算；40 秒的實測約 US$0.011 |
| App 大小 | 2.9 MB | 預算 15 MB |
| 閒置 | CPU 0.0%、約 60 MB | 非正式，見第 3 節 |
| 測試 | 338 個 | `make test` |

前兩列的算法和 DESIGN.md 9.10 節的門檻不同（門檻從講者開口或說完算起），不能直接比較。

## 10. 等專案負責人決定的事

1. `m2/assemble` 要不要推上 GitHub、合併進 `main`。
2. 暫定譯文怎麼顯示（要看實際的畫面）。
3. 要不要更新那張被系統拒絕的開發者憑證。更新之後，重新編譯就不會每次都重新詢問授權。
4. API 實驗的花費上限。
5. M2–M4 的 173 個新測試要不要補審。
6. DESIGN.md 12.2 節原有的六項：更多真實錄音、最低系統需求、時程、Library 的位置、Developer ID 與 Bundle ID（目前暫用 `io.github.ruan330.thunderflow`）、人工評分。
