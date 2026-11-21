# M0b 實驗報告：純轉錄連線加文字模型

> **日期**：2026-11-20
> **狀態**：完成。
> **對應**：[M0 報告](m0-report.md) 3.1 節留下的另一個方向，以及第 4 節的兩個未解問題。
> **要回答的問題**：即時字幕要不要從「`gpt-realtime-translate` 的中文」改成「`gpt-live-transcribe` 轉錄英文，再用文字模型翻成中文」？

---

## 1. 結論

1. **新做法可行，而且每一項都比即時翻譯連線好或相當。**

   | | 即時翻譯連線（`gpt-realtime-translate`） | 純轉錄＋文字模型（本報告） |
   |---|---|---|
   | 中文 | 簡體、中國大陸用語、標點時有時無 | 台灣繁體；術語 19／19、數字 8／8 |
   | 第一個中文字（距離開口） | 中位數 2.7–3.1 秒 | 中位數 2.0–2.3 秒 |
   | 整句中文（距離說完） | 中位數 2.2–2.7 秒，P95 3.2–4.8 秒 | 中位數 1.5–1.9 秒，P95 1.6–2.7 秒 |
   | 每小時費用 | 約 2.04 美元 | 約 1.2–1.3 美元 |
   | 每小時頻寬 | 約 450–500 MB | 約 223 MB |

2. **英文的句號來得比最後一個字晚很多。** 兩種連線都一樣：最後一個字在說完後約 0.5 秒出現，句號卻要等下一句開口才出現，約 1.0–1.5 秒。M0 報告估計「說完後 1.5–1.8 秒出現完整中文」沒有算到這一點，偏樂觀；在即時翻譯連線上實際是 1.9–2.2 秒。
3. **純轉錄連線可以由用戶端在停頓時送出 commit，把這段等待縮短。** 停頓 300 ms 就 commit，英文在說完後約 0.7 秒確定。這是它比即時翻譯連線快的主要原因。
4. **關鍵詞是必要的。** 每一段音訊是各自辨識的。沒有關鍵詞時，AgentCore 會寫成 agent core、Karpenter 會寫成 carpenter；給了關鍵詞後全部寫對。
5. **句子說到一半就先翻譯（暫定譯文）可以讓中文提早約 3.5 秒出現**，代價是每次更新大約有一半的字會改動，費用從每小時 0.03 美元增加到 0.12 美元。

**建議**：v1 的即時字幕採用新做法，`gpt-realtime-translate` 留作備案。需要專案負責人確認（DESIGN.md 的 D3）。

**最大的未知**：全部用合成語音測試，講者的停頓很規律。真人說話會在句子中間停頓，停頓偵測與切段的門檻要用真實錄音校正（第 4 節）。

---

## 2. 結果

### 2.0 實驗條件與限制

- **音檔**：和 M0 相同的合成語音（`say`），加上一段新的 `names`（難唸的產品名稱與一個虛構的人名，34 秒、6 句）。
- **限制**：
  - 合成語音沒有雜訊、口吃與不規則的停頓，句子之間固定停 0.35 秒以上。真實演講的結果一定比較差。
  - 每個設定只跑一次。數字是觀察值，不是統計結論。
  - 錯字率會把數字寫法不同（thirty percent／30%）也算成錯，所以只用來互相比較，並另外列出真正聽錯的字。
- **做法**：
  - `thunderbench transcribe`：以即時速度把音檔送到純轉錄連線，錄下所有事件與時間。
  - `transcript-latency.py`：把收到的英文字和稿子做序列比對，算每句的延遲。不依賴伺服器給的時間欄位，兩種連線用同一套算法。
  - `pipeline.py`：把錄下來的英文時間軸接上「切段 → 文字模型」。英文每個字到達的時間來自紀錄；翻譯是真的呼叫 API，量它花多久，再接在觸發時間後面。沒有做的是讓兩條連線真的同時運作，所以互相影響沒有量到。
- **費用**：
  - 純轉錄連線：26 次執行共送出 53.0 分鐘的音訊，API 回報的計費秒數合計 57.4 分鐘，依公告價格約 0.98 美元。
  - 文字模型：約 0.07–0.10 美元。
  - 合計約 1.05–1.1 美元，比事前估的 1 美元多 5–10%。實際金額請以 OpenAI 的用量頁為準。

### 2.1 連線與設定

| 項目 | 結果 |
|---|---|
| 網址 | `wss://api.openai.com/v1/realtime?intent=transcription`，不帶 `model` |
| 建立連線 | 開始連線到 `session.created`：中位數 0.23 秒（0.17–0.67 秒，46 次）。比即時翻譯連線（約 0.87 秒）快 |
| 預設值 | `transcription: null`、`turn_detection: server_vad`。所以一定要送設定 |
| 設定 | `session.update`（`type: "transcription"`、模型、`turn_detection: null`）。送出到收到 `session.updated`：中位數 0.14 秒 |
| 設定被拒絕 | 回 `error` 事件（`code`、`param`、`message`），沒有 `session.updated`。實測會被拒絕的設定：`delay` 的值不合法；`turn_detection: server_vad`（訊息：這個模型不支援）；同時給 `language` 與 `languages`；`prompt` 超過 1,024 個字元 |
| 會被接受的設定 | `delay`（`minimal`／`low`／`medium`／`high`／`xhigh`）、`keywords`（5,000 個仍被接受）、`prompt`、`languages`（`en`、`zh-tw`、`zh-TW` 都可以）、`noise_reduction`（實測 `far_field`） |
| 連線上限 | `expires_at` 是連線後 3,600 秒，和即時翻譯連線相同。這次最長只測到 10 分鐘 |
| 送音訊 | `input_audio_buffer.append`（base64 的 PCM16、24 kHz） |
| 文字事件 | `conversation.item.input_audio_transcription.delta`：一次大約一個字（平均 5 個字元），帶 `item_id`，沒有任何時間欄位。**不用 commit 也會持續送出** |
| commit | `input_audio_buffer.commit` → `input_audio_buffer.committed`（帶 `item_id`）→ `conversation.item.added`／`done` → `…transcription.completed`（完整文字與 `usage`） |
| 增量與完成的文字 | 543 段全部相同。文字只往後加，沒有看到改寫 |
| 計費 | 完成事件帶 `usage: {"type": "duration", "seconds": N}`，N 是這一段的秒數無條件進位。一句一段時合計比音訊長度多 10–15%（10 分鐘的測試：600 秒的音訊計費 665 秒） |
| 比即時更快地送 | 可以。以 4 倍速送出 93 秒的音訊，文字與即時速度的結果 99% 相同 |
| 其他模型 | `gpt-realtime-whisper` 也能用在這種連線、也接受 `delay`，但**不接受 `keywords` 與 `prompt`**。`gpt-transcribe` 的設定也被接受（沒有測音訊） |
| 頻寬 | 上行約 220 MB／小時（和即時翻譯連線相同）；下行約 3 MB／小時 |

### 2.2 延遲設定（`delay`）

keynote、不送 commit（整段音訊最後才 commit），每個設定一次。單位是秒，「中位數／P95」。

| 設定 | 每句第一個字（距離開口） | 每句最後一個字（距離說完） | 句號（距離說完） | 真正聽錯的字 |
|---|---|---|---|---|
| `minimal` | 0.37／0.66 | −0.14／0.00 | 0.69／0.87 | 另一次執行出現 Latency → Laygency、AgentCore Runtime → agent coruntime |
| `low` | 0.62／1.09 | 0.15／0.41 | 0.87／1.28 | 沒有 |
| `medium`（預設值） | 0.97／1.24 | 0.55／0.65 | 1.20／1.56 | 沒有 |
| `high` | 1.07／1.56 | 0.69／0.86 | 1.33／1.90 | 沒有 |
| `xhigh` | 1.13／1.82 | 0.69／0.84 | 1.31／2.14 | 沒有 |
| （對照）即時翻譯連線裡的英文 | 0.80／1.21 | 0.51／0.62 | 1.11／1.52 | 沒有 |

- `minimal` 會在一個字還沒說完時就把它寫出來（所以是負的），代價是會聽錯。
- 不指定 `delay` 的結果和 `medium` 一樣。
- 設定越低，數字越常寫成英文（one point five billion、thirty percent），句子也切得比較碎（Good morning, everyone. And welcome…）。這對翻譯沒有影響：文字模型照樣翻成「15 億」「30%」。
- 帶口音的 `meeting`：`low` 聽錯 3 個字（cutover took → cut overtook、a pull → apple、our → power），`medium` 只剩 1 個（our → power）。即時翻譯連線裡的英文在同一段音檔上沒有聽錯字，只漏了 2 個 and。

### 2.3 句號為什麼晚到，以及 commit 的效果

**現象**：兩種連線的英文都是這樣。每句的最後一個字很快出現，句號卻常常和下一句的第一個字一起出現。

```
句子在 8.34 秒說完，下一句在 8.69 秒開始
即時翻譯連線： agents@8.98   .@10.18  Amazon@10.19
純轉錄連線：   agents@9.08   .@9.81   Amazon@9.91
```

靠句號切句，等的就是這段時間：說完後約 0.9–1.2 秒（P95 1.2–1.9 秒）。

**commit 的效果**（keynote、`low`，除非另外註明）：

| 何時 commit | 英文確定的時間（距離說完，中位數／P95） | 觀察 |
|---|---|---|
| 不 commit，等句號 | 0.87／1.28 秒 | 整場是一段，專有名詞與數字的寫法最好 |
| 停頓 300 ms | 0.77／0.89 秒（完成事件）；有關鍵詞的那次 0.69／0.84 | 每句一段。commit 到完成事件約 0.5 秒 |
| 同上，`lecture`／`meeting` | 0.73／0.88、0.70／0.89 秒 | |
| 同上，10 分鐘連續（122 句） | `low` 0.68／0.85 秒；`medium` 0.74／0.95 秒 | 各輪之間沒有變慢 |
| 停頓 150 ms（逗號處也切） | 0.57／0.69 秒 | 19 句被切成 34 段，每段各自加句號、各自辨識（下面的例子） |
| 固定每 5 秒 | — | 切點前後的字會錯：hours → Towers、evaluation → eval／Situation，還多出不存在的字（Nurses） |
| 停頓 500 ms | — | 這段音檔的停頓都不到 500 ms，等於沒有 commit |

- **commit 之後定稿的時間和 `delay` 幾乎無關**（`low` 0.68、`medium` 0.74 秒）。`delay` 只影響句子進行中的字出現得多早。
- **commit 不能太積極。** 停頓 150 ms 的結果：

  ```
  Amazon Bedrock agent core gives you three core components.
  A runtime.
  A gateway
  And memory
  With Agent coroutine time
  Each session runs in its own isolated microVM for up to eight hours.
  ```

- **不能在說話中途切。** 固定間隔的結果說明伺服器不會幫忙把切點前後接起來。
- **一段的結尾不一定有句號。** `low` 設定、有關鍵詞的那次，19 句裡有 7 句在 commit 時沒有句號；10 分鐘的測試是 23／122（`low`）與 19／122（`medium`）。所以切段要以「這一段完成了」為準，不能只看句號。
- 靠句號加上 0.2 秒的確認（沒有別的字接上來），或完成事件，兩者取早的：英文在說完後 0.58–0.64 秒確定（P95 0.68–0.86 秒）。

### 2.4 正確率與關鍵詞

**keynote 的 7 個專有名詞**（Amazon Bedrock、AgentCore、Graviton5、Graviton4、microVM、S3 Vectors、CloudWatch）：

| 設定 | 照原樣出現 | 寫錯的例子 |
|---|---|---|
| 不 commit、沒有關鍵詞（`low` 與 `medium`） | 5／7 | Graviton 5、Graviton 4（多了空格） |
| 停頓就 commit、沒有關鍵詞（三次） | 3／7、3／7、4／7 | agent core、micro VM、Graviton Five、S3 vectors、availability zones |
| 停頓就 commit、有關鍵詞（`low` 與 `medium`） | 7／7 | — |
| 不 commit、有關鍵詞 | 7／7 | — |
| （對照）即時翻譯連線裡的英文 | 7／7 | 20 分鐘那次有 5 輪寫成 Graviton Five |

**names**（難唸的名稱；停頓就 commit、`low`）：

| | 結果 |
|---|---|
| 稿子 | Doctor Anneliese Okonkwo-Reyes／Strands Agents and the Model Context Protocol／SageMaker HyperPod using Trainium3／Bedrock Knowledge Bases／Karpenter on EKS Auto Mode／FSx for Lustre |
| 沒有關鍵詞 | Dr. **Annalisa Conqueray**／**transagents in** the model context protocol／SageMaker hyperpod using **Tranium three**／Bedrock knowledge bases／**carpenter on X auto mode**／**FSX for Luster** |
| 有關鍵詞 | 全部寫對，只有 Trainium3 寫成 Trainium 3 |

**10 分鐘連續**（三段音檔輪流、有 keynote 的關鍵詞、122 句）真正聽錯的字：

| | 聽錯的字 |
|---|---|
| `low` | agents → agent（2 次）、our → power（2 次） |
| `medium` | agents → agent（2 次） |
| （對照）即時翻譯連線 20 分鐘、247 句 | and 被漏掉（4 次）、Graviton5 → Graviton Five（5 次） |

結論：有關鍵詞時，三者的英文在合成語音上沒有明顯差別。`medium` 比 `low` 略準，句子進行中的字晚約 0.4 秒。

### 2.5 接上文字模型之後的端到端延遲

`gpt-6-luna`（Responses API、串流、`reasoning.effort: none`）。每一段附前兩段英文當上下文。

**整句中文定稿出現的時間（距離這一句說完）**

| 英文來源 | 音檔 | 英文確定（中位數／P95） | 中文定稿（中位數／P95） |
|---|---|---|---|
| 純轉錄、`low`、停頓 300 ms 就 commit | keynote（有關鍵詞） | 0.58／0.71 | **1.47／1.59** |
| 同上 | lecture | 0.59／0.70 | **1.49／1.85** |
| 同上 | meeting | 0.62／0.80 | **1.54／1.79** |
| 同上 | 10 分鐘連續（122 句） | 0.59／0.82 | **1.54／2.08** |
| 同上，`medium` | 10 分鐘連續（122 句） | 0.64／0.86 | **1.58／2.46** |
| 同上（文字模型比較慢的兩次） | keynote（沒有關鍵詞） | 0.61／0.68 | 1.77–1.92／2.62–2.71 |
| 純轉錄、`low`、不 commit、等句號 | keynote | 0.92／1.29 | 1.78／2.27 |
| 即時翻譯連線的英文、等句號 | keynote、lecture、meeting | 0.96–1.10／1.25–1.53 | 1.90–2.18／2.30–2.95 |
| 同上 | 20 分鐘連續（247 句） | 1.19／2.06 | 2.16／3.51 |
| （對照）即時翻譯連線自己的中文 | keynote、lecture、meeting | — | 2.2–2.7／3.2–4.8 |

- 文字模型本身：每段 0.86–1.13 秒（中位數），P95 1.1–2.0 秒。同一段音檔不同次執行就差到 0.3 秒，所以上表各列之間 0.3 秒以內的差距不代表做法有差別。
- 文字模型偶爾會卡住：約 1,700 個請求裡有 2 個花了 61 與 72 秒才回來。用戶端一定要設逾時並重試。

**第一個中文字出現的時間（距離這一句開口）**

| 做法 | 中位數／P95 |
|---|---|
| 只有定稿（整句說完才翻） | 4.9–6.3／7.0–8.8 秒 |
| 加上暫定譯文（每多 3 個字、至少隔 1 秒，把目前的半句送去翻譯） | **2.0–2.3／2.4–3.3 秒** |
| （對照）即時翻譯連線自己的中文 | 2.7–3.1／3.4–4.8 秒 |

**暫定譯文長什麼樣子**（keynote 的一句；時間是送出翻譯請求的時間，譯文約 0.6–0.9 秒後出現）：

```
英文：Today I want to talk about how we are making it easier to build production-ready agents.
暫定  4.81 秒  今天我想
暫定  5.98 秒  今天我想談談我們如何
暫定  6.99 秒  今天我想談談我們如何讓這件事變得更容易
暫定  8.39 秒  今天我想談談我們如何讓打造可投入正式環境的系統變得更容易
定稿  9.02 秒  今天我想談談，我們如何讓打造可投入正式環境的代理程式變得更簡單。
```

- 每次更新，平均只有 50–56% 的開頭保持不變（一共約 950 次更新）。中英文語序不同，後面的字出現後前面常常要改寫。
- 半句偶爾會翻出怪字，例如「…價格效能最高提升 30% 七喜」（英文停在 than），下一次更新就消失。
- 每句平均 3 次暫定翻譯。

**譯文品質**（有關鍵詞的定稿）：keynote 全部是繁體字，術語 19／19、數字 8／8。keynote 與 names 的例句：

> Amazon Bedrock AgentCore 提供 3 個核心元件：執行環境、閘道和記憶體。
> 使用 AgentCore Runtime 時，每個工作階段都會在獨立的 microVM 中執行，最長可達 8 小時。
> 我們也宣布推出 Graviton5，價格效能比 Graviton4 最多提升 30%。
> 請歡迎領導 agentic platform 團隊的 Anneliese Okonkwo-Reyes 博士。
> 您可以在 EKS Auto Mode 上執行 Karpenter，並將檢查點儲存在 FSx for Lustre。

英文寫錯的專有名詞會原樣帶進中文（沒有關鍵詞時：「在 X auto mode 上執行 carpenter」）。文字模型有時能修回來（agent core → AgentCore），但不穩定。

### 2.6 10 分鐘連續串流

keynote、lecture、meeting 輪流播放 10 分鐘，停頓 300 ms 就 commit，有關鍵詞。`low` 與 `medium` 各一次，同時進行。

| | `low` | `medium` |
|---|---|---|
| 段數 | 125，全部完成，沒有失敗 | 125，全部完成，沒有失敗 |
| 錯誤事件、斷線 | 0 | 0 |
| commit 到完成事件 | 中位數 0.47、P95 0.63、最長 1.68 秒 | 中位數 0.54、P95 0.71、最長 1.74 秒 |
| 英文定稿（距離說完） | 0.68／0.85 秒 | 0.74／0.95 秒 |
| 各輪的句號延遲（中位數） | 0.38、0.38、0.33 秒 | 0.43、0.46、0.42 秒 |
| 計費秒數 | 665（音訊 600 秒） | 665 |

- 沒有看到越跑越慢。每一段是各自處理的，不像即時翻譯連線會累積狀態。
- 最長的那次完成事件（1.7 秒）兩次都是同一句（7.1 秒長、數字很多）。

### 2.7 遇到的異常

全部 543 段、約 1,700 個翻譯請求裡，看到這些：

| 異常 | 次數 | 內容 |
|---|---|---|
| 一段被截斷，而且完成事件很晚 | 1／543 段 | commit 之後 6.7 秒才收到完成事件，文字只有「That is the power」，後半句不見了。計費秒數也只有 2 秒（那一段是 3.7 秒） |
| 文字模型的請求卡住 | 2／約 1,700 | 61 秒與 72 秒才回來 |
| 暫定譯文出現怪字 | 少數 | 見 2.5 節 |

### 2.8 來源不是英文

`mixed`（中文、英文、中英夾雜），`languages: ["en", "zh-tw"]`：

- 中文、英文都完整轉錄，第一句沒有被略過（即時翻譯連線會略過）。中英夾雜的句子也正確：「我们的 inference endpoint部署在三个 availability zone，latency大概是两百毫秒」。
- **中文仍然以簡體輸出**，`zh-tw` 這個語言提示沒有改變字形。
- 送進文字模型後，輸出是台灣繁體：「我們的推論端點部署在 3 個可用區域，延遲大約是 200 毫秒。」原本就是中文的句子等於被轉成繁體並稍微潤飾。

### 2.9 費用與頻寬

| | 即時翻譯連線＋逐句翻譯 | 純轉錄＋文字模型 |
|---|---|---|
| 語音服務 | 0.034 美元／分鐘 → 2.04 美元／小時（英文逐字稿若另外計費是 3.06） | 0.017 美元／分鐘，加上每段進位的 11% → 約 1.13 美元／小時 |
| 文字模型 | 約 0.03 美元／小時 | 只有定稿約 0.03；加上暫定譯文約 0.12 美元／小時 |
| 合計 | 約 2.07 美元／小時 | 約 1.16–1.25 美元／小時 |
| 上行 | 約 220 MB／小時 | 約 220 MB／小時 |
| 下行 | 約 225–280 MB／小時 | 約 3 MB／小時 |

---

## 3. 對設計的影響

已經寫進 DESIGN.md v0.3 草稿（5.6 節與相關章節）。重點：

1. **即時字幕的引擎改成四個部分**：停頓偵測 → 轉錄連線 → 切段 → 翻譯。錄音路徑（M1）不用改。
2. **中文分兩層**：暫定譯文與定稿。暫定譯文只顯示在最後一行、用淡色，可以關閉。
3. **字幕事件要帶段號**，英文和它的中文用段號配對。逐字稿的中英對照因此天生對齊。
4. **關鍵詞成為 v1 的功能**：場次資訊、設定頁的詞表、這一場選填的關鍵詞。
5. **不再需要簡體轉繁體的詞表**（OpenCC 資料檔）。
6. **commit 的規則**：說話之後停頓 300 ms 才送；沒有說話不送；不在說話中途硬切。
7. **切段的規則**：句號加上 0.2 秒確認，或一段音訊完成，取早的；不能只看句號。
8. **逾時與重試**：文字模型的請求設逾時；完成事件 3 秒沒到就以增量文字為準。
9. **會後的「重翻中文」改為「精修」**：補上沒翻到的段、統一術語、把零碎的句子整理成段落。
10. **費用顯示**：轉錄以每段進位後的秒數計；加上文字模型的 token。

---

## 4. 還沒回答的問題

- **真人演講。** 這是最大的未知，而且新做法比舊做法更依賴它：
  - 真人會在句子中間停頓，停頓 300 ms 就 commit 可能把句子切碎（2.3 節的 150 ms 例子就是切碎之後的樣子）。
  - 現場的雜訊、背景音樂會影響用音量判斷停頓。
  - 英文辨識在真實口音與遠距收音下的差異。
  - 需要 2–3 段真實的錄音（各 5–10 分鐘）才能校正門檻。在那之前，M2 可以先用合成語音與這次錄下的事件開發。
- **很久沒有停頓時會怎樣。** 最長只測到一段 93 秒不 commit。更長的段有沒有上限還不知道。
- **靜音與閒置的計費。** 沒有 commit 的靜音是否計費、連線閒置是否計費，只能從 OpenAI 的用量頁確認。
- **連線能不能撐到 60 分鐘。** 這次最長 10 分鐘。設計上 45 分鐘換線，並把無預警斷線當成一般情況。
- **API Key 無效時的行為**在純轉錄連線上沒有測（M0 測的是即時翻譯連線）。
- **大量關鍵詞對正確率的影響。** 5,000 個會被接受，但會不會造成誤判還沒測。
- **即時翻譯連線能不能也用關鍵詞。** 它接受把英文逐字稿的模型換成 `gpt-live-transcribe`（實測），但沒有測關鍵詞。就算可以，它仍然沒有 commit，費用也仍然是兩倍。
- **兩條連線同時運作時互相的影響**，以及在慢的網路上的表現。

---

## 5. 重現方式

```sh
cd Tools/thunderbench && swift build -c release
B=../../Benchmarks; R=$B/data/runs

# API Key 只從 Keychain 讀進環境變數，不寫進任何檔案
export OPENAI_API_KEY="$(security find-generic-password -a "$USER" -s thunderflow-openai-dev -w)"

# 只送設定、不送音訊（免費）：看某個設定會不會被接受
.build/release/thunderbench transcribe --no-audio --out $R/probe --delay low --languages en

# 即時速度串流：low、有關鍵詞、停頓 300 ms 就 commit
.build/release/thunderbench transcribe $B/data/keynote.wav --out $R/c-keynote --languages en --delay low \
    --commit silence:300 --keywords $B/synthetic/keywords-keynote.txt

# 英文的延遲與錯字（translate 與 transcribe 的輸出都能用）
./transcript-latency.py $R/c-keynote $B/data/keynote.json --terms $B/synthetic/terms.json --name keynote

# 接上文字模型：定稿＋暫定譯文
./pipeline.py $R/c-keynote $B/data/keynote.json --trigger turn --partials --show
.build/release/thunderbench analyze $R/c-keynote/pipeline-turn-partials --terms $B/synthetic/terms.json --name keynote
```

- 每次執行的完整紀錄在 `Benchmarks/data/`，不進 repo。
- 整理過、可以提交的事件紀錄在 `Benchmarks/fixtures/openai-transcribe/`（說明見該資料夾的 README），供 M2 的引擎測試重播。
