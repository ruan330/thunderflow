# 純轉錄連線的事件紀錄（M0b）

把合成語音以即時速度送到 `wss://api.openai.com/v1/realtime?intent=transcription`（`gpt-live-transcribe`）時，
實際收到的事件。給 M2 的引擎測試重播用。產生方式見 [M0b 報告](../../results/m0b-report.md) 第 5 節。

## 格式

一行一筆 JSON，依時間順序：

- 伺服器的事件：`{"event": {…}, "rx_ms": 1407, "sent_ms": 1400}`
  - `rx_ms`：收到的時間，從開始送音訊算起（毫秒）。開始送音訊之前收到的事件沒有這個欄位。
  - `sent_ms`：當時已經送出多少音訊（毫秒）。以即時速度送出時，它等於當下的音訊位置。
- 用戶端的動作：`{"client": "commit", "rx_ms": 3618, "sent_ms": 3620, "reason": "silence", "turn_seconds": 3.62, "index": 1}`
  - 重播時靠它知道何時送出了 commit。`reason` 是 `silence`（偵測到停頓）、`interval`（固定間隔）或 `end`（音訊結束）。

工作階段的 id 已改成 `sess_REDACTED`。事件裡沒有 API Key。

## 檔案

| 檔案 | 音檔 | 設定 | 用途 |
|---|---|---|---|
| `keynote-commit-on-pause.jsonl` | keynote（93 秒、19 句） | `delay: low`、關鍵詞、停頓 300 ms 就 commit | 正常的一場：20 段，多數是一段一句（最後一段是結尾的靜音，文字是空的）。v1 預計使用的設定 |
| `keynote-single-turn.jsonl` | keynote | `delay: low`、全部送完才 commit | 只靠增量文字與句號切段的情況 |
| `keynote-truncated-turn.jsonl` | keynote | `delay: medium`、停頓 300 ms 就 commit | 第 18 段的完成事件在 commit 之後 6.7 秒才到，而且後半句不見了（That is the power） |
| `keynote-fragments.jsonl` | keynote | `delay: low`、停頓 150 ms 就 commit | 逗號處也被切開：34 段，句子變成碎片，每片各自加句號 |
| `keynote-4x.jsonl` | keynote | 同 `keynote-commit-on-pause`，以 4 倍速送出 | 補送積壓音訊的情況 |
| `names-with-keywords.jsonl` | names（34 秒、6 句） | `delay: low`、關鍵詞 | 難唸的人名與產品名稱都寫對了（只有 Trainium3 多了一個空格） |
| `names-without-keywords.jsonl` | names | `delay: low`、沒有關鍵詞 | 同一段音檔，專有名詞寫錯（carpenter、transagents） |
| `mixed-zh-en.jsonl` | mixed（27 秒、6 句） | `languages: ["en", "zh-tw"]` | 來源是中文、英文與中英夾雜；中文以簡體輸出 |
| `combo-10min.jsonl` | keynote、lecture、meeting 輪流，共 10 分鐘 | `delay: low`、關鍵詞、停頓 300 ms 就 commit | 長一點的連續串流：125 段 |
| `rejected-delay.jsonl` | 沒有送音訊 | `delay: "bogus"` | 設定被拒絕：`error` 事件、`code: invalid_value` |
| `rejected-turn-detection.jsonl` | 沒有送音訊 | `turn_detection: server_vad` | 設定被拒絕：這個模型不支援伺服器端的斷句 |

另外有一個不是事件的檔案：

- `keynote.pauses.json`：keynote 音檔裡每一次停頓的時間（最後一格語音結束、偵測到停頓），以及每一句的起訖與文字。
  停頓由 `Tools/thunderbench/vad-plan.py` 以預設值算出。和 `keynote-*.jsonl` 一起重播，用來測切段。

音檔的稿子在 `Benchmarks/synthetic/`，每句的起訖時間由 `thunderbench synth` 產生（不進 repo，可以重新產生）。
