# ThunderFlow 設計文件

> **狀態**：草稿 v0.1（待審查）
> **日期**：2026-11-20
> **範圍**：v1
>
> 本文件由原本的長版規格精簡而來，是 v1 開發的唯一依據。審查者請先讀第 0 節。

---

## 0. 給審查者

這份文件回答三件事：**v1 做什麼、怎麼做、怎樣算完成。**

- 已定案的決策列在第 11 節，每項都附理由與放棄的選項。
- 需要專案負責人決定的事項列在第 12.2 節。
- 所有外部 API 的事實都在 2026-11-20 查證過，來源列在第 10 節。標示「待 M0 驗證」的是目前未知、要靠實驗確認的部分。
- 和原始規格相比，刪掉了哪些東西，請見第 2.2 節與第 11 節。
- 請依第 13 節的審查清單提出意見。最有價值的回饋是：
  - 漏掉了會讓核心功能失效的東西；
  - 還可以再刪掉的東西；
  - 事實錯誤。

---

## 1. 產品定義

**一句話**：按一個鍵開始，即時看到英文和台灣繁體中文字幕；結束後得到一份完整紀錄，包含錄音、中英逐字稿和摘要，而且全部可以在 App 裡清楚地瀏覽。

| 項目 | 內容 |
|---|---|
| 產品名稱 | ThunderFlow（雷霆） |
| App | ThunderFlow.app（macOS 原生） |
| Repository | `thunderflow` |
| 開發團隊 | Relevance |
| 定位 | Open-source Realtime AI Translation：開源、macOS 原生、Local-first、BYOK（使用者自備 API Key） |
| 使用情境 | AWS re:Invent 等研討會、實體課程、線上會議（Zoom、Meet、Teams）、YouTube 與 Udemy、Podcast |
| 語言 | v1 的來源語言是英文，目標語言是台灣繁體中文 |

### 1.1 四個核心能力

v1 的目標是把這四件事做到極致：

1. **即時翻譯**：講者說英文時，畫面即時出現英文逐字稿與台灣繁體中文翻譯。
2. **錄音**：完整保存整場錄音，任何情況下都不能遺失。
3. **中英逐字稿**：保存中英對照、標有時間的逐字稿。
4. **摘要**：結束後自動產生摘要與附時間的章節，讓紀錄容易回顧。

所有相關功能都在 App 內以簡潔、清楚的方式呈現。介面風格參考 OpenAI API Platform：左側導覽、大量留白、清楚的表格、每頁只有一個主要動作。

### 1.2 優先順序

兩個目標互相衝突時，依照以下順序取捨：

1. 錄音完整性與穩定性
2. 即時翻譯速度
3. 英文辨識與中文翻譯品質
4. macOS 原生操作體驗
5. 資料與 API 憑證安全
6. 擴充能力
7. 開源社群易用性

---

## 2. 範圍

### 2.1 v1 功能清單

**四個核心能力**

- **即時翻譯**
  - 英文逐字稿與繁中翻譯同時顯示。
  - 可切換「雙語／只看中文／只看英文」，字級可以調整。
- **錄音**
  - 整場錄音保存成一個 `recording.m4a`。
  - 可以暫停、繼續。
- **逐字稿**
  - 中英對照、標有時間，存成 `transcript.md`。
  - 在 App 內可以瀏覽、搜尋，點一下段落就跳到錄音的對應位置。
- **摘要**
  - 結束後自動產生（可以關閉），也可以手動重新產生。
  - 內容包括一句話總結、重點、附時間的章節、名詞對照、待辦事項。
  - 使用者沒有命名的場次，會自動用摘要內容命名。

**讓核心能力能用的四件基本功**

- **收音**
  - 麥克風：內建、USB、iPhone（接續互通相機）、藍牙。
  - 系統音訊：擷取所有 App 的聲音，但排除 ThunderFlow 自己。
  - 引導使用者授權，並提供測試。
- **API Key**
  - 第一次啟動時引導輸入，存在 Keychain。
  - 可以測試、顯示或隱藏、刪除。
- **不遺失資料**
  - 遇到當機、斷網、連線到期、裝置拔除、闔上螢幕、磁碟空間不足時，錄音要繼續，或是安全地收尾。
  - 字幕要能自動恢復。
- **瀏覽介面**：即時翻譯頁、浮動字幕視窗、過去錄音清單、單場詳細頁（摘要、逐字稿、播放器）、設定頁。

**小功能**（成本低，但直接提升體驗）

- 錄音中可以「標記重點」。標記會出現在逐字稿中，也會提供給摘要使用。
- 在 Finder 中顯示該場的資料夾。
- 刪除場次（移到垃圾桶）。
- 顯示本場的預估費用。

### 2.2 v1 不做

| 功能 | 處理方式 |
|---|---|
| AWS 與其他 AI 服務商 | 保留引擎介面，之後再加入（D10） |
| 會後精修逐字稿（重新辨識） | v1.x 第一優先候選 |
| Apple 本機的免費／離線模式 | v1.x 候選 |
| 術語字典 | 等改用可以接受 prompt 的引擎時再做 |
| 多種匯出格式（SRT、VTT、JSON、CSV、ZIP） | 不做，資料夾本身就是成品 |
| App 外的全文搜尋 | 交給 Spotlight（已驗證會索引 `.md`）；App 內提供基本搜尋 |
| 選單列、全域快捷鍵、費用警示 | 之後再做 |
| 會議雙音軌（同時錄自己的聲音）、只擷取指定 App 的聲音 | 之後再做 |
| 講者辨識、本機 AI、跨場次問答 | 之後再做 |
| 在 App 內編輯逐字稿 | 之後再做（使用者可以直接編輯 Markdown 檔，但 App 不會同步） |

### 2.3 設計原則

1. **App 只做四件事：收音、轉送、顯示、存檔。** 斷句、降噪、翻譯都交給引擎。
2. **錄音永遠最先處理，而且不依賴網路。** 翻譯或網路出任何錯，都不能影響錄音。
3. **檔案就是資料。** 每一場都是使用者看得到的資料夾，不使用資料庫。
4. **v1 不依賴任何第三方套件**，只用 Apple SDK。
5. **每個元件都必須對應一個 v1 需求**，沒有對應就不做。
6. **先量測，再決定。** 用哪個引擎、驗收門檻設多少，都由實測決定。

---

## 3. 名詞

| 名詞 | 定義 |
|---|---|
| 場次（Session） | 從使用者按下開始到結束的一次錄音，對應一個資料夾 |
| 連線（Connection） | 與 AI 服務之間的一條 WebSocket。一個場次可能經歷多條連線（重新連線、換線） |
| 引擎（Engine） | 把音訊轉成字幕事件的元件，例如 OpenAI 即時翻譯 |
| 段落（Block） | 逐字稿的基本單位：一段 20–60 秒的英文加上對應的中文，附開始時間 |
| 音訊時間 | 從場次開始算起、扣掉暫停的錄音時間。所有時間戳都用它，不受系統時鐘變更影響 |
| Library | 存放所有場次資料夾的使用者資料夾，預設是 `~/Documents/ThunderFlow` |
| 工作目錄 | 錄音中的暫存位置：`~/Library/Application Support/ThunderFlow/Working/` |

---

## 4. 使用者體驗與介面

### 4.1 介面原則

參考 OpenAI API Platform：

- **導覽**：左側固定導覽列，只有三項：即時翻譯、過去錄音、設定。
- **視覺**：淺色模式白底、深色模式深灰底，跟隨系統設定。使用灰階細框線、單一強調色、系統字型、SF Symbols。
- **按鈕**：每頁只有一個主要按鈕，其他都是次要按鈕。
- **狀態**：用小標籤顯示，例如「錄音中」「處理中」「完成」「已復原」「摘要失敗」。
- **空白狀態**：一句說明，加上一個按鈕。
- **錯誤訊息**：顯示在頁面頂端的橫幅，說清楚三件事：發生了什麼、錄音有沒有受影響、使用者該怎麼處理。
- **元件**：使用 SwiftUI 原生元件（`NavigationSplitView`、`Table`、`Form`），保持 macOS 原生的操作手感。

### 4.2 首次啟動（三個步驟）

1. **輸入 API Key**：貼上 OpenAI API Key，按「測試」。測試會呼叫免費的 `GET /v1/models`。
2. **授權麥克風與系統錄音**，然後按「測試系統音訊」：App 會播放提示音，確認有收到聲音。系統音訊權限被拒時，macOS 只會給靜音，不會回報錯誤，所以只能用這種方式檢查。
3. **確認資料夾位置**（預設 `~/Documents/ThunderFlow`），完成。

### 4.3 即時翻譯頁

```
即時翻譯
標題：[未命名（選填）]       來源：[系統音訊 ▾]          [● 開始錄音]
──────────────────────────────────────────────────────────────────
● 即時   00:42:17   ▂▃▅▇▅▃   預估 $1.43        [標記重點] [浮動字幕]

中文
  今天我們要談的是如何打造可以上線的 Agent……
  AgentCore 提供三個元件……

English
  Today we're going to talk about building production-ready agents...
  AgentCore gives you three components...
                                                       [↓ 回到最新]
```

- **版面**：中文為主（大字），英文為輔（小字、灰色），上下兩區各自自動捲動。
- **捲動**：使用者往上捲動時，暫停自動捲動，並出現「回到最新」按鈕。
- **顯示模式**：雙語／只看中文／只看英文。
- **狀態**：錄音狀態與翻譯狀態分開顯示。翻譯斷線時會顯示「翻譯重新連線中，錄音持續中」。
- **場次資訊**：開始前可以選填標題、活動名稱、講者。不填也沒關係，結束後會用摘要自動命名。
- **暫停與停止**：可以暫停和繼續。按下停止後進入結束處理流程（5.7 節），並自動跳到這一場的詳細頁。

### 4.4 浮動字幕視窗

- 使用 `NSPanel`，永遠顯示在最上層。可以跨越所有桌面空間，也能疊在全螢幕 App 上（`canJoinAllSpaces`、`fullScreenAuxiliary`）。
- 可以移動、縮放、調整透明度，可以選雙語或單語。
- 顯示最新的 1–2 句中文和 1 句英文。
- 選項：
  - 「滑鼠穿透」：點擊會直接穿過字幕視窗，作用在底下的視窗。
  - 「螢幕分享時隱藏」：使用 `sharingType = .none`。這個設定在新版 macOS 上對 ScreenCaptureKit 是否有效，需要實測。

### 4.5 過去錄音（清單頁）

```
過去錄音                                   [搜尋標題、摘要、逐字稿…]
──────────────────────────────────────────────────────────────────
標題                                日期          時長      狀態
今天
  Building Agents with Bedrock      12/02 10:30   58:12     完成
    介紹 AgentCore 的三個元件與部署方式……
本週
  機器學習導論 第 3 講              11/27 14:00   1:42:05   完成
    梯度下降、學習率與過擬合……
```

- **排序**：依日期分組（今天、本週、本月、更早），由新到舊。
- **每一列**：標題、日期時間、時長、狀態標籤、摘要第一句。
- **搜尋**：同時比對標題、摘要和逐字稿。直接在記憶體中掃描，不建立索引。
- **右鍵選單**：在 Finder 中顯示、重新產生摘要、刪除（移到垃圾桶）。

### 4.6 單場詳細頁

```
← 過去錄音
Building Agents with Bedrock                     [在 Finder 中顯示] [⋯]
2026-12-02 10:30 · 58:12 · 系統音訊 · gpt-realtime-translate · 約 $1.98
──────────────────────────────────────────────────────────────────
[ 摘要 ]  [ 逐字稿 ]

  一句話：AgentCore 讓 Agent 從原型走到正式環境……
  重點
   • …
  章節
   00:00:12  開場與問題定義
   00:08:40  AgentCore 的三個元件
──────────────────────────────────────────────────────────────────
 ▶  ━━━━━━━●──────────────  12:31 / 58:12    1×    ⟲15  15⟳
```

- **摘要分頁**：一句話總結、重點、章節（點時間就跳到錄音對應位置）、名詞對照、待辦事項。
- **逐字稿分頁**：
  - 中英對照的段落，每段都標有時間。
  - 點段落就跳到錄音對應位置；播放時會標示目前播放的段落。
  - 按 ⌘F 可在這一場內搜尋。重點標記以旗標顯示。
- **底部固定播放器**：
  - 播放／暫停（空白鍵）、拖曳進度。
  - 播放速度：1×、1.25×、1.5×、2×。
  - 前後跳 15 秒。
- **「⋯」選單**：重新產生摘要、複製全文（中文、英文或雙語）、重新命名、刪除。

### 4.7 設定頁

- **API**
  - OpenAI API Key：遮罩顯示，可以顯示／隱藏、測試、刪除。
  - 進階設定（預設收合）：Base URL、即時翻譯模型、摘要模型。
- **音訊**：預設來源與裝置、權限狀態與修復按鈕、測試系統音訊。
- **字幕**：字級、顯示模式、浮動視窗透明度、滑鼠穿透、螢幕分享時隱藏。
- **摘要**：結束後是否自動產生。
- **儲存**：資料夾位置、已使用的空間。
- **隱私**：清楚列出哪些資料會送到哪裡（見第 6 節）。

### 4.8 App 內快捷鍵

| 快捷鍵 | 功能 |
|---|---|
| ⌘N | 開始新錄音 |
| ⌘. | 停止 |
| ⌘B | 標記重點 |
| ⌘⇧F | 開關浮動字幕 |
| 空白鍵 | 播放／暫停 |
| ⌘F | 搜尋 |

全域快捷鍵不在 v1 範圍內。

### 4.9 多語系與無障礙

- 介面字串一律使用 String Catalog。v1 提供繁體中文與英文介面。
- 字幕字級可以調整；主要控制項都有 VoiceOver 標籤。

---

## 5. 系統架構

### 5.1 總覽

```
麥克風／系統音訊（Core Audio HAL IOProc）
   │ 即時執行緒：只做 memcpy
   ▼
RingBuffer（單一生產者單一消費者、lock-free、事先配置好記憶體）
   │ Pump：每 20–50 ms 取一次
   ├─► CAF 分段寫入（工作目錄）          ← 永遠最先做，與網路無關
   ├─► 音量表／靜音判斷
   └─► 轉成 24 kHz PCM16 ─► LiveCaptionEngine（OpenAI 即時翻譯或 Mock）
                                │ CaptionEvent（英文、中文、狀態、用量）
                                ▼
                       captions.jsonl（只追加寫入）＋ UI 模型（合併後每秒最多更新 30 次）

停止後：CAF → recording.m4a
        captions → 段落對齊 → transcript.md
        → 摘要 → summary.md
```

### 5.2 模組

一個本地 Swift package（`Packages/ThunderKit`），包含四個 library target 和一個 CLI：

| Target | 職責 | 依賴 |
|---|---|---|
| `ThunderCore` | 資料模型、`CaptionEvent`、段落組裝、資料夾讀寫、產生 Markdown、Keychain、價格表 | Foundation、Security |
| `ThunderAudio` | HAL 擷取（麥克風、Process Tap）、`FileAudioSource`、RingBuffer、格式轉換、寫入 CAF、合併成 m4a | Core、CoreAudio、AVFoundation |
| `ThunderEngines` | `OpenAITranslateEngine`、`MockEngine`、`Summarizer` | Core |
| `ThunderSession` | 場次流程：Pump、錄音、串接引擎、暫停與恢復、記錄缺口、結束處理、當機復原 | Core、Audio、Engines |
| `thunderbench`（CLI） | 實驗（spike）與 benchmark | 以上全部 |

依賴規則：

- App target 只放 SwiftUI／AppKit 介面，以及把各部分組裝起來的程式碼。
- Engines 不依賴 Audio。
- UI 不直接使用 Audio 或 Engines，一律透過 Session。
- 場次流程放在獨立的 `ThunderSession`，是為了讓整合測試不需要 UI 就能跑。

### 5.3 並行模型（Swift 6 strict concurrency）

| 執行環境 | 負責 | 禁止 |
|---|---|---|
| HAL IO 執行緒（即時） | 把樣本 memcpy 進 RingBuffer | 配置記憶體、使用鎖、寫 log、`await`、傳送 Objective-C 訊息 |
| Pump（專用 Task） | 讀 RingBuffer、寫 CAF、計算音量、轉換格式、送給引擎 | 阻塞 UI |
| 引擎 actor | WebSocket 收送、重新連線、換線 | 寫檔 |
| `@MainActor` UI 模型 | 顯示；事件合併後每秒最多更新 30 次 | 做繁重的工作 |

- RingBuffer 使用 `Synchronization.Atomic` 實作單一生產者單一消費者的佇列，外層以 `@unchecked Sendable` 包裝。
- RingBuffer 要有壓力測試，並在 Thread Sanitizer 下執行。
- 容量至少能存 10 秒的音訊。

### 5.4 音訊擷取

- **統一走 HAL IOProc**：麥克風與系統音訊都用 HAL IOProc 擷取，兩種來源共用一套程式碼。不用 AVAudioEngine，因為它在 macOS 上預設跟著系統裝置走，要指定裝置或處理插拔都很麻煩。
- **系統音訊**：使用 Core Audio Process Tap（`CATapDescription`，擷取全部 App 但排除自己的 process），搭配一個私有的 aggregate device。不使用 ScreenCaptureKit，因為它需要「螢幕錄製」權限，對使用者來說太重。
- **裝置清單**：動態偵測，不寫死裝置名稱。iPhone 麥克風（接續互通相機）在系統中就是一個普通的輸入裝置。
- **裝置消失時**（例如拔掉 USB 麥克風，或是 iPhone 被拿起來解鎖）：自動改用系統預設的輸入裝置，記錄缺口，並顯示提示。
- **權限**：Info.plist 中設定 `NSMicrophoneUsageDescription` 與 `NSAudioCaptureUsageDescription`。
- **防止睡眠**：錄音中呼叫 `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`。不過闔上螢幕仍然會睡眠，所以：
  - 收到 `willSleep` 時，先把目前的 CAF 分段寫完；
  - 喚醒後自動開新分段、重新連線引擎，並記錄缺口。
- **取樣率變更**：監聽裝置的取樣率。一旦變更，就結束目前分段，以新格式開新分段。

### 5.5 錄音

- **錄音中**：
  - 在工作目錄裡，每 10 分鐘寫一個 CAF 檔。
  - 格式：裝置原生取樣率、單聲道、16-bit PCM。48 kHz 時約 345 MB／小時。
- **為什麼不用 WAV**：WAV 有 4 GB 上限，而且當機後檔頭資訊會錯誤。CAF 規格允許把資料區塊的大小標成「一直延續到檔尾」，比較容易復原。
- **磁碟空間**：
  - 開始前先檢查，剩餘空間低於 2 GB 時發出警告。
  - 錄音中低於 500 MB 時，安全地收尾並提示使用者。
- **結束後**：
  - 依序把所有分段合併、編碼成 `recording.m4a`（AAC、單聲道、64 kbps，約 29 MB／小時）。
  - 確認時長一致後，才刪除 CAF 檔。
- **當機復原**：
  - App 啟動時檢查工作目錄，找出狀態仍是「錄音中」的場次。
  - 修復最後一個 CAF 檔，照常產生所有成品，並把場次標記為「已復原」。

### 5.6 即時翻譯引擎

#### 5.6.1 介面

```swift
public protocol LiveCaptionEngine: Sendable {
    func start(_ config: LiveSessionConfig) async throws -> AsyncStream<CaptionEvent>
    func send(_ chunk: AudioChunk) async      // 已轉成引擎需要的格式
    func pause() async                        // 關閉連線（不送靜音，避免被計費）
    func resume() async
    func finish() async                       // 正常收尾，等待最後的輸出
}

public enum CaptionEvent: Sendable {
    case source(text: String, kind: TextKind, at: AudioTime)       // 英文
    case translation(text: String, kind: TextKind, at: AudioTime)  // 中文
    case status(EngineStatus)    // connecting / live / reconnecting / paused / failed(reason)
    case gap(from: AudioTime, to: AudioTime, reason: GapReason)
    case usage(audioSeconds: Double)
}

public enum TextKind: Sendable { case delta, segmentEnd }
```

服務端不提供時間戳，所以 `at` 由引擎在收到事件的當下，填入「目前已送出的音訊時間」。

#### 5.6.2 v1 候選引擎：`OpenAITranslateEngine`

| 項目 | 內容 |
|---|---|
| 連線 | `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`，標頭 `Authorization: Bearer <key>` |
| 設定 | 連線後送出 `session.update`：<br>・`session.audio.output.language`：目標語言（中文的語言代碼待 M0 確認）<br>・`session.audio.input.transcription.model = "gpt-realtime-whisper"`：取得英文原文<br>・`session.audio.input.noise_reduction`：現場麥克風用 `far_field`，系統音訊設為 `null`<br>（欄位路徑以官方文件為準，待 M0 驗證） |
| 送出音訊 | `session.input_audio_buffer.append`：base64 編碼的 PCM16、24 kHz、單聲道。官方建議每包 200 ms，M0 會實測 100 ms 和 200 ms 的差異 |
| 接收文字 | 英文：`session.input_transcript.delta`<br>中文：`session.output_transcript.delta`<br>語音：`session.output_audio.delta`，直接丟棄 |
| 結束 | 送出 `session.close`，等收到 `session.closed` 後才關閉 socket |
| 費用 | $0.034／分鐘（英文原文的轉錄是否另外計費，待 M0 確認） |

#### 5.6.3 連線生命週期

- **預先連線**：按下開始時立即開始錄音，同時建立連線；連線建好後，再補送這段時間的音訊。
- **重新連線**：
  - 使用指數退避加上隨機抖動，等待時間依序為 1、2、4、8 秒……，最長 30 秒。
  - 斷線 10 秒以內的音訊會保留下來，連上後補送。
  - 超過 10 秒的部分直接丟棄並記錄缺口；連線恢復後優先翻譯當下的音訊。
- **換線**：
  - 連線滿約 50 分鐘後換線。一般 Realtime 連線的上限是 60 分鐘，translation 端點的上限官方沒有公布。
  - 等到下一次停頓（音量低於閾值持續 300 ms 以上），先建好新連線再切換過去，舊連線正常收尾。
- **錯誤處理**：
  - 401（API Key 無效）或額度不足：停止翻譯，錄音繼續，用橫幅引導使用者到設定頁。
  - 429（請求過多）：退避後重試，並在畫面上顯示。
  - 網路錯誤：重新連線。
- **暫停**：直接關閉連線。官方要求連線期間必須持續送音訊，送靜音同樣會被計費。

#### 5.6.4 中文正規化（依 M0 結果決定是否需要）

- **如果輸出是簡體**：
  - 先用 ICU 的 `Hans-Hant` 把簡體字轉成繁體字。
  - 再套用一份台灣用語詞表。詞表取自 OpenCC 的詞表資料檔（Apache-2.0 授權），只使用資料檔，不使用它的 C++ 函式庫。
- **為什麼一定要詞表**：實測發現 ICU 只轉字、不轉詞。「軟件、數據庫、視頻」不會變成「軟體、資料庫、影片」。
- **轉換單位**：以整句為單位轉換，不要逐一轉換每個 delta，因為詞彙轉換需要上下文。

#### 5.6.5 備案

如果 M0 顯示術語或用語無法接受，改用兩段式串接：

- 用 `gpt-live-transcribe` 轉錄英文。它可以接受 `prompt` 與 `keywords`，費用 $0.017／分鐘。
- 再用文字 LLM 逐句翻譯，翻譯時可以附上術語表和前文。
- 代價：要由用戶端自己決定何時送出一段（`turn_detection: null`，由用戶端 commit），因此多了一個斷句元件。

### 5.7 結束處理流程

```
停止 → 錄音收尾 → m4a 合併 → 段落對齊 → transcript.md → 摘要 → summary.md → 搬進 Library → 完成
```

- 任何一步失敗，都不影響前面已經完成的成品。狀態標籤會顯示目前進行到哪一步。
- **段落對齊**：英文和中文之間沒有共同的 ID，也沒有時間戳，所以用以下規則對齊：
  1. 依句號與停頓，把英文切成 20–60 秒的段落。
  2. 估計翻譯延遲 L：計算「英文句尾出現時間」與「對應中文句尾出現時間」之差的移動平均。
  3. 每個中文句子，歸到「出現時間減去 L」所落入的英文段落。
  4. 段落的時間，取英文第一句出現的時間再減 2 秒，讓點擊跳轉時寧可早一點開始。

  這是初版規則。M0 時要確認事件內容裡有沒有可以直接用來對齊的資訊。

### 5.8 摘要

- **觸發**：結束後自動產生（可在設定中關閉），也可以手動重新產生。
- **輸入**：附時間的英文段落，加上場次資訊。使用英文原文，是因為它比即時中文翻譯準確。
- **呼叫方式**：OpenAI Responses API，使用 JSON Schema 結構化輸出。模型 ID 可以在設定中修改。
- **輸出結構**：由 App 自己把 JSON 排版成 `summary.md` 和畫面，不直接採用模型自由輸出的 Markdown。

```json
{
  "title": "string",
  "one_liner": "string",
  "key_points": ["string"],
  "chapters": [{ "start_sec": 0, "title": "string", "summary": "string" }],
  "glossary": [{ "en": "string", "zh": "string" }],
  "action_items": ["string"]
}
```

- **規則**：
  - 使用台灣繁體中文與台灣用語，專有名詞保留英文。
  - 章節時間必須落在錄音長度之內。
  - 沒有待辦事項時回傳空陣列。
- **長場次**：超過約 3 小時時，每 60 分鐘分段摘要，最後再合併。
- **失敗時**：場次仍然算完成，只標記「摘要失敗」，可以重試。
- **自動命名**：使用者沒有命名的場次，用 `title` 自動命名，並同步重新命名資料夾。

### 5.9 資料與檔案

```
~/Documents/ThunderFlow/                         ← Library（可在設定中更改）
└── 2026-12-02 1030 Building Agents with Bedrock/
    ├── recording.m4a
    ├── transcript.md
    ├── summary.md
    └── .thunderflow/
        ├── session.json    ← 小檔：標題、時間、時長、來源、引擎、狀態、費用、標記
        └── captions.json   ← 大檔：段落（開始時間、英文、中文）、缺口
```

- **讀取**：
  - App 啟動時只讀每個資料夾裡的小檔 `session.json`，清單就能顯示出來。
  - 大檔 `captions.json` 等到打開詳細頁或搜尋時才讀。
- **識別**：
  - 場次用 `session.json` 裡的 `id` 識別，資料夾名稱只是給人看的。資料夾名稱會去除檔名不允許的字元。
  - 使用者在 Finder 裡搬移或改名資料夾，不會造成問題。App 回到前景時會重新掃描。
- **寫入**：一律先寫進暫存檔，再以原子方式取代原檔。
- **錄音中的檔案**：只存在工作目錄，結束後才搬進 Library。這樣做，是為了避免使用者的「文件」資料夾有開 iCloud 同步時，在演講途中就開始上傳好幾 GB 的暫存檔。
- **刪除**：移到垃圾桶（`NSWorkspace.recycle`），不直接永久刪除。
- **格式版本**：每個 JSON 都有 `schemaVersion` 欄位，供日後升級格式使用。
- **一般設定**：存在 UserDefaults。API Key 只存在 Keychain。
- **為什麼刻意不用資料庫**：
  - 8 小時的逐字稿也只有 1–2 MB，幾百場的資料直接在記憶體裡掃描就夠快了。
  - 如果驗收時清單或搜尋速度不達標（9.4 節），再加入 SQLite，但只當作可以重建的索引。檔案永遠是唯一的資料來源。

`transcript.md` 範例：

```markdown
# Building Agents with Bedrock
2026-12-02 10:30 · 58:12 · 系統音訊

### 00:00:12
So today we're going to talk about building production-ready agents...

今天我們要談的是如何打造可以上線的 Agent……
```

---

## 6. 隱私與安全

- **API Key**：只存在 Keychain（`kSecClassGenericPassword`，service 名稱為 Bundle ID）。不寫進任何檔案、log、設定或匯出內容。
- **Log**：使用 `os.Logger`，預設不記錄逐字稿內容，也不記錄 API Key。
- **資料流向**（在設定頁清楚顯示）：

| 資料 | 送到哪裡 | 什麼時候 |
|---|---|---|
| 音訊 | OpenAI（即時翻譯） | 錄音中且翻譯開啟時 |
| 英文逐字稿文字 | OpenAI（摘要） | 產生摘要時 |
| 其他所有資料 | 不離開本機 | — |

- **不蒐集使用資料**：不收集任何使用資料，也沒有遙測。
- **連線對象**：只連到使用者設定的端點，預設是 `api.openai.com`。
- **錄音提醒**：第一次錄音時提醒使用者，確認現場允許錄音，也允許使用第三方 AI 處理。

---

## 7. 平台、建置與發布

- **系統需求**：macOS 26 以上，只支援 Apple Silicon（建議，待確認）。
  - 所有 Apple Silicon Mac 都能升級到 macOS 26。
  - v1.x 的本機模式可以直接使用 `SpeechAnalyzer`、`TranslationSession` 等 API，少寫相容分支。
- **語言與工具**：Swift 6 語言模式，開發環境為 Xcode 26 以上。
- **App Sandbox**：不開啟。Process Tap 和未來讀取 `~/.aws` 都需要在 Sandbox 外執行。
- **Hardened Runtime**：開啟，entitlement 為 `com.apple.security.device.audio-input`。
- **簽章**：
  - 開發期間至少要用 Apple ID 的 Personal Team 簽章。如果用 ad-hoc 簽章，每次重新編譯，Keychain 和系統權限都會重新詢問。
  - 正式發布使用 Developer ID 簽章並通過公證。費用由誰負擔待定。
- **發布管道**：GitHub Releases（zip 或 dmg）。
- **授權**：MIT（待確認）。

---

## 8. 專案結構

```
thunderflow/
├── ThunderFlow.xcodeproj
├── App/                    # SwiftUI／AppKit：Live、Library、Settings、Onboarding、FloatingCaption
├── Packages/ThunderKit/
│   ├── Package.swift
│   ├── Sources/            # ThunderCore、ThunderAudio、ThunderEngines、ThunderSession、thunderbench
│   └── Tests/              # 每個 target 各自的測試
├── Benchmarks/             # 資料集清單、合成語音腳本、結果報告（不含音檔）
├── .github/workflows/ci.yml
├── DESIGN.md
├── CLAUDE.md
├── README.md
├── SECURITY.md
├── CONTRIBUTING.md
└── LICENSE
```

---

## 9. 測試與驗收

### 9.1 原則

1. **測試不依賴麥克風或真人**：使用「音檔重播（`FileAudioSource`）加上 `MockEngine`」，所有自動測試都能在 CI 上執行。
2. **量測功能內建在 App 裡**：每個事件都記錄收到的時間與音訊時間。Benchmark 和介面上的延遲顯示使用同一份資料。
3. **先量測，再定門檻**：以 M0 的實測結果當作基準。之後只要表現退步超過門檻，就擋下不合併。

### 9.2 五層測試

| 層 | 內容 | 何時執行 | 費用 |
|---|---|---|---|
| 1 單元測試 | 見下方清單 | 每個 PR | 0 |
| 2 整合測試 | 音檔 → MockEngine → 完整的結束流程，加上故障注入（見下方） | 每個 PR | 0 |
| 3 加速長跑 | 8 小時的音訊用 50 倍速（約 10 分鐘）跑完，檢查樣本數、記憶體、分段數量、成品完整性 | 每晚、發布前 | 0 |
| 4 Benchmark | 真實引擎、真實資料、1 倍速重播 | 修改引擎時 | 每次約 US$1–3 |
| 5 實機與實地測試 | 硬體檢查清單（9.6 節）、實際的演講或課程 | 發布前 | — |

- **第 1 層單元測試涵蓋**：
  - RingBuffer（含 Thread Sanitizer 壓力測試）、取樣率轉換。
  - CAF 分段與復原。
  - 事件解析：使用 M0 錄下的真實事件當測試資料。
  - 段落對齊、Markdown 產生。
  - 重新連線的退避邏輯：使用假時鐘測試。
  - 資料夾讀寫與原子寫入。
- **第 2 層故障注入情境**：第 30 秒斷線、429、401、伺服器無回應、連線到期、磁碟已滿、裝置消失、睡眠與喚醒。

第 2 層的核心檢查只有一條：**不論引擎出什麼錯，錄到的樣本數都必須等於輸入的樣本數**。裝置切換或睡眠造成的缺口，必須被記錄下來。

### 9.3 Benchmark

- **真實音訊資料集**：
  - 6–8 段，每段 5–10 分鐘，涵蓋：技術演講、教室裡的遠距收音、線上會議、非美式口音、數字與版本號很密集的段落。
  - 每段都附上：人工校對過的英文稿（含每句的起訖時間）、台灣繁中參考譯文、20–40 個術語。
  - 音檔與參考稿放在私人位置；repo 只放清單、腳本與結果。
- **合成語音資料集**：
  - 用 macOS 的 `say` 唸我們自己寫的稿子，內容充滿 AWS 術語與數字。
  - 一句一句分別產生語音再串接起來，所以每句的起訖時間都精確已知。
  - 沒有授權問題，標準答案也精確，可以放進 repo 做回歸測試。只用來抓退步，不用來評品質。
- **延遲的量法**：用最小編輯距離，把引擎的輸出對齊回參考稿的每一句（做法類似 IWSLT 同步口譯評測），得到以下三個指標：
  - **首字延遲**（每句計算）：該句第一個中文字出現的時間，減去講者開口的時間。
  - **句末延遲**：該句最後一個中文字出現的時間，減去講者說完的時間。
  - **改寫率**：字幕上了畫面之後，又被修改的字數比例。
- **輸出**：JSON 與 Markdown 報告，提交到 `Benchmarks/results/`。

### 9.4 驗收指標

以下是 v1 的初始門檻，M0 完成後會再校正。

| 優先 | 指標 | 量法 | 門檻 |
|---|---|---|---|
| 1 | 錄音樣本完整性 | 第 2、3 層測試加上嗶聲測試 | 0 遺失（已記錄的缺口除外） |
| 1 | 程式被強制結束 | `kill -9` | 損失 ≤ 1 秒；重新啟動後自動復原並產生成品 |
| 1 | 斷網 30 秒 | 故障注入，加上實機關閉 Wi-Fi | 錄音不中斷；網路恢復後 ≤ 5 秒重新出現字幕 |
| 1 | 連續 8 小時 | 加速長跑，加上一次真實長跑 | 不當機；穩定後記憶體成長 ≤ 50 MB |
| 2 | 首字延遲 | Benchmark | P50 ≤ 3 秒 |
| 2 | 句末延遲 | Benchmark | P95 ≤ 5 秒 |
| 2 | 收到事件到顯示在畫面上 | os_signpost | P95 ≤ 50 ms |
| 3 | 英文 WER | Benchmark | 先量出基準 |
| 3 | 術語正確率 | 和術語清單比對 | ≥ 90% |
| 3 | 簡體字與中國大陸用語 | 自動掃描 | 0 |
| 3 | 譯文品質 | 人工抽 30 句，每句評 1–5 分 | 平均 ≥ 4 |
| 3 | 摘要品質 | 人工評 5 場：涵蓋度、正確性、有無捏造 | 平均 ≥ 4；捏造為 0 |
| 3 | 章節時間準確度 | 點擊章節後的位置，與實際內容開始處的差距 | ≤ 10 秒 |
| 4 | 摘要產生時間 | 1 小時的錄音 | ≤ 60 秒 |
| 4 | 開啟清單 | 500 場紀錄 | ≤ 1 秒 |
| 4 | 全文搜尋 | 500 場紀錄 | ≤ 2 秒 |
| 4 | CPU 使用率（雲端模式） | 定期取樣 | 平均 ≤ 5% |
| 5 | 憑證外洩 | 設定一把假 Key 跑完整個流程，再掃描所有檔案與系統 log | 出現 0 次 |
| 5 | 連線目的地 | 連線層可以替換，測試時記錄所有連線 | 只連到設定的端點 |
| 7 | 新使用者上手 | 用全新的 macOS 帳號，從下載正式簽章版 App 到看見第一個字幕 | ≤ 3 分鐘 |
| 7 | 開發者上手 | 從 git clone、編譯到看見第一個字幕 | ≤ 10 分鐘 |

### 9.5 嗶聲測試

播放一個每秒嗶一聲的音檔，錄下來之後，檢查相鄰兩聲嗶的間隔是不是 1.000 秒。只要中間掉了任何一段音，間隔就會出現異常。

這個測試用來在實機上驗證：麥克風、系統音訊、裝置切換、睡眠與喚醒。

### 9.6 實機檢查清單（發布前）

- [ ] 內建麥克風
- [ ] USB 麥克風
- [ ] iPhone 麥克風（錄音途中拿起手機）
- [ ] AirPods
- [ ] 戴著耳機播放 YouTube（系統音訊）
- [ ] Zoom 通話
- [ ] 闔上螢幕後再打開
- [ ] 關閉 Wi-Fi 30 秒
- [ ] 磁碟空間不足
- [ ] 拒絕權限後的引導流程
- [ ] 多螢幕與全螢幕下的浮動字幕
- [ ] 螢幕分享時隱藏浮動字幕

### 9.7 完成定義

- **M0 完成**：spike 報告完成，D3 定案。報告內容包含：
  - 3 段音檔的實測：簡體或繁體、術語正確率、延遲。
  - 連續使用 70 分鐘以上的連線行為。
  - 頻寬用量。
- **v1 完成**：
  - 第 1–3 層測試在 CI 上全部通過；
  - 9.4 節的指標全部達標；
  - 實機檢查清單全部通過；
  - 在實際場合完整跑完 3 場、每場 45 分鐘以上的演講或課程，全程不需要人工介入。

---

## 10. 已查證的外部事實（2026-11-20）

| 事實 | 來源 |
|---|---|
| `gpt-realtime-translate`（2026-05-07 發布）使用專用端點 `/v1/realtime/translations`。支援 13 種輸出語言，中文只列出「Chinese」，沒有 zh-TW 選項，也沒有說明輸出簡體或繁體 | [1][2][3] |
| `gpt-realtime-translate` 的限制：<br>・不支援自訂 prompt 與術語表，官方也承認可能把名稱、實體翻錯<br>・一定會輸出語音<br>・費用 $0.034／分鐘，建議每包音訊 200 ms，連線期間必須持續送音訊<br>・要取得英文原文，需另外設定 `gpt-realtime-whisper` 轉錄<br>・文件沒有提到時間戳 | [1][2][3] |
| `gpt-live-transcribe` 與 `gpt-realtime-whisper` 都是 $0.017／分鐘。前者支援 `prompt`、`keywords`、`languages`、`delay`。兩者都要求 `turn_detection: null`，由用戶端 commit | [4][6] |
| 檔案轉錄：`gpt-transcribe` 為 $0.0045／分鐘；`whisper-1` 與 `gpt-4o-transcribe` 系列將在 2027-02-26 停用；上傳檔案上限 25 MB；只有 `whisper-1` 支援逐字時間戳 | [5][6] |
| 一般 Realtime 連線的時長上限是 60 分鐘 | [7] |
| Apple Translation 支援英文翻成 zh-Hant-TW。開發機（M1 Max、macOS 27.0.1）實測每句 0.75–1.1 秒；品質可用，但會出現「數據」等用語 | 本機實測 |
| `SpeechTranscriber` 在 macOS 27.0.1 上支援 45 個語系，包含 en_US | 本機實測 |
| ICU 的 `Hans-Hant` 只轉字，不轉詞 | 本機實測 |
| Spotlight 會索引 `.md` 檔的內容，包含中文 | 本機實測（`mdimport`） |
| （供 v1.x 參考）Amazon Transcribe 串流約 $0.01／分鐘（us-east-1），按秒計費、沒有最低收費；Amazon Translate 為 $15／百萬字元，支援 `zh-TW`；自訂術語不保證一定會套用 | [8][9][10] |

**來源**

1. https://developers.openai.com/api/docs/guides/realtime-translation
2. https://developers.openai.com/api/docs/models/gpt-realtime-translate
3. https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide
4. https://developers.openai.com/api/docs/guides/realtime-transcription
5. https://developers.openai.com/api/docs/guides/speech-to-text
6. https://developers.openai.com/api/docs/pricing
7. https://developers.openai.com/blog/realtime-api
8. https://aws.amazon.com/transcribe/pricing/
9. https://aws.amazon.com/translate/pricing/
10. https://docs.aws.amazon.com/translate/latest/dg/how-custom-terminology.html

---

## 11. 決策紀錄

| # | 決策 | 理由 | 放棄的選項 |
|---|---|---|---|
| D1 | v1 範圍＝四個核心能力＋四件基本功（2.1 節） | 集中資源，把核心做到極致 | 原規格的多服務商、匯出、術語、搜尋等全套功能 |
| D2 | 需要 macOS 26 以上、Apple Silicon（待確認） | 所有 Apple Silicon Mac 都能升級；使用新 API 可少寫相容分支 | macOS 15：涵蓋的使用者稍多，但要多寫很多 `#available` |
| D3 | v1 只做一個雲端引擎，候選是 `gpt-realtime-translate`，由 M0 定案 | 引擎自己斷句，App 最簡單，延遲可能也最低 | 同時做好幾種模式再比較：成本太高 |
| D4 | v1 不依賴任何第三方套件 | 編譯快、沒有供應鏈風險、方便社群貢獻 | GRDB、OpenCC、AWS SDK、KeyboardShortcuts |
| D5 | 檔案就是資料：每場一個資料夾，不使用資料庫 | 不怕當機、資料透明、不需要匯出、Spotlight 搜得到 | SQLite／GRDB（日後可當作可重建的索引） |
| D6 | 麥克風與系統音訊都走 HAL；系統音訊使用 Process Tap | 只需一套擷取程式碼，需要的權限範圍最小 | AVAudioEngine（切換裝置麻煩）、ScreenCaptureKit（需要螢幕錄製權限） |
| D7 | 錄音中使用 CAF 分段，結束後產出 m4a | 錄音中不怕當機；成品好用、檔案小 | WAV（4 GB 上限、當機後難救）；保留無損原檔（日後可做成選項） |
| D8 | 摘要使用結構化 JSON 輸出，由 App 自行排版 | 章節時間可靠、畫面呈現一致 | 直接儲存模型輸出的 Markdown |
| D9 | 不開 Sandbox，開 Hardened Runtime，用 Developer ID 發布 | Process Tap 與未來讀取 `~/.aws` 都需要 | 上架 Mac App Store |
| D10 | AWS 延後。屆時自行撰寫輕量的 SigV4 client，Profile／SSO 憑證交給 `aws configure export-credentials` 處理 | 避開最重的第三方套件 | AWS SDK for Swift |
| D11 | 介面參考 OpenAI API Platform 的簡潔風格，使用原生 SwiftUI 元件 | 清楚、好用、符合 macOS 原生 | 自訂的花俏設計 |

---

## 12. 里程碑、待決事項與風險

### 12.1 里程碑

| 里程碑 | 內容 | 完成條件 |
|---|---|---|
| M0 實驗 | 寫一個 `thunderbench` CLI：把音檔串流到 `gpt-realtime-translate`，記錄所有事件與時間。費用約 US$3–4 | 9.7 節的 M0 條件 |
| M1 骨架 | Package 與各 target、`FileAudioSource`、RingBuffer、CAF 寫入、`MockEngine`、`captions.jsonl`、最基本的 UI、CI | 第 1–3 層測試全部通過 |
| M2 即時翻譯 | HAL 擷取麥克風與 Process Tap、`OpenAITranslateEngine`、即時翻譯頁與浮動字幕、重新連線與換線、首次啟動引導 | 能在實際演講中完整使用 |
| M3 紀錄 | 結束處理流程（m4a、段落對齊、`transcript.md`）、過去錄音清單、詳細頁與播放器、搜尋、當機復原 | 清單與搜尋的指標達標 |
| M4 摘要 | Summarizer、`summary.md`、點章節跳轉、自動命名 | 摘要的指標達標 |
| M5 發布 | Benchmark、長跑測試、實地測試、簽章與公證、README | 9.7 節的 v1 條件 |

如果要趕在特定活動之前可以用：先完成 M0–M2，以及 M3 裡「存檔」的部分。清單介面和摘要可以之後再補，因為資料都已經存下來了，摘要可以事後再對舊場次產生。

### 12.2 待專案負責人決定

1. 最低系統需求是否定為 macOS 26？（建議是）
2. 時程：是否要在今年 re:Invent 之前就能使用？
3. Library 預設位置是否用 `~/Documents/ThunderFlow`？
4. Developer ID 的費用由誰負擔？Bundle ID 用哪個網域？
5. 授權是否採用 MIT？
6. 人工評分（譯文、摘要）由誰負責？

### 12.3 已知風險

| 風險 | 處理方式 |
|---|---|
| `gpt-realtime-translate` 輸出簡體字或中國大陸用語 | M0 驗證；依 5.6.4 節做正規化 |
| 術語翻錯，而且無法用 prompt 修正 | M0 驗證；採用 5.6.5 節的備案 |
| 英文與中文之間沒有共同的 ID 或時間戳 | 依 5.7 節做段落對齊；M0 時確認事件內容 |
| translation 端點的連線上限沒有公布 | M0 時連續跑 70 分鐘以上觀察；無論結果如何，都在 50 分鐘時換線 |
| 下行語音約 230 MB／小時（用不到，但無法關閉） | M0 實測；在文件中提醒使用手機熱點的使用者 |
| 系統音訊權限被拒時，只會收到靜音 | 首次啟動與設定頁都提供測試 |
| 來源不是英文時（例如中文演講、中英夾雜），translate 不會輸出中文 | v1 只保證英文來源；M0 時順便觀察 |
| Swift 6 strict concurrency 與即時音訊執行緒的衝突 | 即時相關的程式碼集中在少數幾個型別，並加上 Thread Sanitizer 壓力測試 |
| Library 位於 iCloud 同步的資料夾 | 錄音中只寫入工作目錄；設定頁偵測到時提醒使用者 |

---

## 13. 審查清單

請審查者至少回答下列問題：

1. **範圍**：v1 是否漏掉了會讓四個核心能力失效的東西？有沒有還可以再刪掉的？
2. **引擎**：`gpt-realtime-translate` 不支援術語，也沒有 zh-TW 選項。在這個前提下，把它當作 v1 的首選合理嗎？備案夠不夠？
3. **對齊**：5.7 節的段落對齊規則可行嗎？有沒有更簡單、更可靠的做法？
4. **可靠性**：還有哪些情況會導致錄音遺失或程式卡住？例如取樣率變更、系統時間變更、多個裝置同時消失。
5. **並行**：5.3 節的並行模型在 Swift 6 下有沒有陷阱？
6. **檔案即資料**：遇到 iCloud 同步、使用者在 Finder 中操作、同時開兩個 App、寫入中途中斷等情況，有沒有風險？
7. **摘要**：結構化輸出、長場次分段、防止捏造的做法是否足夠？
8. **介面**：第 4 節的資訊架構，能不能讓主要流程（開始 → 看字幕 → 結束 → 回顧）足夠直覺？
9. **測試**：9.4 節的指標都能量測嗎？門檻設得合理嗎？
10. **安全與隱私**：第 6 節有沒有遺漏？
11. **事實**：第 10 節有沒有過時或錯誤的地方？
