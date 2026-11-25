# M2 實驗報告：本機語音辨識（Apple SpeechAnalyzer）和 OpenAI 的比較（2026-11-25）

## 結論

1. **準確度幾乎一樣。** 兩場真實的四人會議上，Apple 的 `SpeechTranscriber` 和現在用的 OpenAI `gpt-live-transcribe` 錯字率只差 0.5–1 個百分點。
2. **開 `fastResults` 時，字幾乎一樣快。** 字出現的時間中位數只比 OpenAI 晚 0.1–0.2 秒（P90 晚約 0.5 秒）。不開時晚約 1.5 秒。
3. **英文不穩定，確定得比較晚。**
   - Apple 的英文出現之後，有 30–46% 的字會被換掉（OpenAI 1–3%），畫面上的英文會一直跳。
   - 確定的時間 P90 晚 1.3–4.6 秒。翻譯要等英文確定才送，整句定稿（白字）會跟著晚。
4. **聽寫模型（`DictationTranscriber`）不適合。** 漏字多（錯字率 37–49%）、要 6–20 秒才確定、英文幾乎整段一直改、抓不到句子的邊界。
5. **費用與隱私。** 本機辨識不用錢，聲音不離開電腦，英文字幕不需要網路。OpenAI 每小時 1.02 美元，約佔整場費用的八到九成。
6. **CPU 約多 4–5%（一個核心）。** 辨識在系統的 `localspeechrecognition` 程序裡跑（3.6%），加上送音訊的部分（約 1.3%）。現在錄音中的 App 整體約 8.5%（預算 5%，待負責人決定）。
7. **建議**：做成設定裡的選項（「本機辨識：免費、聲音不離開電腦」），OpenAI 維持預設。先處理英文的改寫（例如只顯示穩定的部分），再用真實會議驗證，確認改寫與白字的延遲可以接受，才考慮改成預設。

## 1. 條件

- **材料**：AMI 會議語料庫（CC BY 4.0）兩場真實的四人會議，各取第 1–11 分鐘。
  - ES2004a：情境會議（一起設計產品），參考稿 1,146 個字。
  - EN2002a：自然的討論，說得快，參考稿 2,183 個字。
  - 音檔是各人耳麥的混音（Mix-Headset，16 kHz），轉成 24 kHz 給兩邊用。參考稿是人工逐字稿，每個字有時間。音檔與逐字稿不進 repo。
  - 之前的真實錄音只有另一個 OpenAI 模型（whisper-1）聽出來的參考稿，拿來比會偏向 OpenAI，所以這次改用人工逐字稿。
- **OpenAI**：`thunderbench live --sentences --no-provisional`，也就是 App 的正式引擎（`gpt-live-transcribe`，`delay` 是 `low`），不給關鍵詞，照實際速度送。
- **Apple**：新的 `thunderbench local`（macOS 27.0.1，en-US，`SpeechAnalyzer`），照實際速度一次送 0.1 秒：
  - `SpeechTranscriber`（預設）與加上 `fastResults`。
  - `DictationTranscriber`（開標點）與加上 `frequentFinalization`。
- **指標**（`Tools/thunderbench/asr-compare.py`）：
  - **錯字率**：兩邊用同一套正規化（小寫、去掉標點、um／uh／hmm 這類口頭聲音不算、數字轉成英文字、ok 當成 okay）後逐字比對。
  - **字出現的延遲**：參考稿裡一個字說完，到畫面上出現這個位置的字（暫時的結果也算）。模擬時每包音訊在它開始的時間就送出，App 要錄完那一包才送得出去，所以加上一包的長度（OpenAI 0.2 秒、Apple 0.1 秒）。
  - **確定的延遲**：說完到這個字所在的那一段確定（OpenAI 的段結束、Apple 的確定結果）。翻譯要等確定才送。
  - **改寫**：英文出現之後又被換掉的字，佔最後字數的比例（照 App 的字幕資料重建畫面，同一個時間點的事件合成一次更新）。
  - **句子的邊界**：參考稿的句號、問號、驚嘆號，和辨識結果有沒有落在同一個字後面（精確率／召回率）。整句模式靠它判斷一句說完。
- **限制**：
  - 參考稿裡多人同時說話的地方依開始時間交錯排列，兩邊都會因此多算刪除（別人插一句「yeah」之類的也常沒聽到），錯字率只能互相比較，不是真正的錯字率。
  - 只有兩場、各 10 分鐘。沒有測關鍵詞（兩邊都支援），也沒有測線上會議經過壓縮的系統音訊。

## 2. 結果

ES2004a（10 分鐘，1,146 個字）：

| | 錯字率 | 替換／刪除／插入 | 字出現的延遲（中位數／P90） | 確定的延遲（中位數／P90） | 改寫 | 句子邊界（精確／召回） |
|---|---|---|---|---|---|---|
| OpenAI | 19.5% | 40／175／8 | 0.49／0.67 秒 | 1.70／3.62 秒 | 3% | 42%／50% |
| Apple SpeechTranscriber | 21.3% | 51／177／16 | 1.92／3.62 秒 | 3.37／6.70 秒 | 26% | 46%／74% |
| **Apple SpeechTranscriber＋fastResults** | **20.0%** | 56／158／15 | **0.60／1.09 秒** | 1.89／4.93 秒 | 30% | 47%／74% |
| Apple DictationTranscriber | 36.6% | 63／356／0 | 0.48／0.76 秒 | 19.84／44.62 秒 | 77% | 29%／19% |
| Apple DictationTranscriber＋frequentFinalization | 36.6% | 63／356／0 | 0.47／0.76 秒 | 5.94／15.25 秒 | 79% | 11%／5% |

EN2002a（10 分鐘，2,183 個字）：

| | 錯字率 | 替換／刪除／插入 | 字出現的延遲（中位數／P90） | 確定的延遲（中位數／P90） | 改寫 | 句子邊界（精確／召回） |
|---|---|---|---|---|---|---|
| OpenAI | 26.9% | 123／447／17 | 0.50／0.69 秒 | 1.63／3.45 秒 | 1% | 52%／46% |
| Apple SpeechTranscriber | 27.9% | 147／445／17 | 2.16／3.76 秒 | 4.06／9.74 秒 | 48% | 54%／56% |
| **Apple SpeechTranscriber＋fastResults** | **27.9%** | 147／444／17 | **0.67／1.20 秒** | 2.70／8.02 秒 | 46% | 56%／60% |
| Apple DictationTranscriber | 48.8% | 111／951／4 | 0.49／0.95 秒 | 16.91／34.53 秒 | 101% | 20%／5% |
| Apple DictationTranscriber＋frequentFinalization | 48.8% | 111／951／4 | 0.48／0.93 秒 | 7.82／20.42 秒 | 102% | 18%／4% |

- `fastResults` 不影響準確度，只讓暫時的結果早出來。
- 在 94 秒的合成語音上，不等待地處理只要 1.6 秒（約 58 倍速）；有標點、大小寫，數字寫成阿拉伯數字；沒給關鍵詞時專有名詞會聽錯（例如 AgentCore）。

## 3. CPU

照實際速度辨識 EN2002a，在辨識進行中取兩次快照（第 20 秒與第 170 秒），算這 150 秒裡每個程序用掉的 CPU 時間（`Tools/thunderbench/cpu-diff.py`；以一個核心為 100%，和活動監視器相同）：

| | 系統的辨識程序（`localspeechrecognition`） | 實驗工具本身（讀檔、轉換格式、寫紀錄） |
|---|---|---|
| SpeechTranscriber＋fastResults | 3.6% | 1.3% |
| DictationTranscriber＋frequentFinalization | 16.3%（另有 Neural Engine 的 `aned` 0.9%） | 1.5% |

- 辨識模型在系統的 `localspeechrecognition` 程序裡跑，App 自己的程序看不到這些 CPU；每一個辨識工作有自己的一個程序，辨識結束就關掉。
- 改用本機辨識時，OpenAI 連線的部分省下來，但要多約 4–5%。
- 沒有量 Neural Engine 與耗電（要 `powermetrics` 與管理員權限）。量測時電腦上同時開著其他 App（全部程序合計約 200%），每個程序的 CPU 時間不受影響。

## 4. 如果要做本機模式

- **英文的顯示**：現在的字幕資料只會往後加字（OpenAI 的增量文字）。Apple 的暫時結果會整段改寫，要加「取代正在說的那一段」的事件，畫面也要能接受英文改寫。
- **切段與翻譯**：段的定稿、整句定稿與暫定譯文都靠英文確定與切段。Apple 確定得比較晚，切段要改成照 Apple 的確定結果，或沿用現在的停頓偵測。
- **句子的邊界**：Apple 的句尾標點比 OpenAI 多（召回 60–74%，精確率差不多），整句模式可以沿用。
- **翻譯照舊用雲端的模型**：只有英文字幕不需要網路。完全離線要再加 Apple 的翻譯（DESIGN.md 10.2 節：每句 0.75–1.1 秒，品質可用，但會出現「數據」等用語）。

## 5. 重現方式

```sh
B=Tools/thunderbench
A=Benchmarks/private/ami
# AMI 的人工逐字稿與音檔：https://groups.inf.ed.ac.uk/ami/download/（ami_public_manual_1.6.2.zip、<會議>.Mix-Headset.wav）
python3 -I $B/ami-reference.py $A/annotations/words ES2004a 60 660 $A/clips/ES2004a-ref.json --audio $A/download/ES2004a.Mix-Headset.wav /tmp/ES2004a-16k.wav
afconvert -f WAVE -d LEI16@24000 -c 1 /tmp/ES2004a-16k.wav $A/clips/ES2004a.wav
# OpenAI（每 10 分鐘約 0.18 美元）；Key 只從 Keychain 讀進環境變數
export OPENAI_API_KEY="$(security find-generic-password -a "$USER" -s thunderflow-openai-dev -w)"
$B/.build/release/thunderbench live $A/clips/ES2004a.wav --sentences --no-provisional --quiet --events openai.jsonl
# Apple（免費）；第一次會下載英文的辨識模型
$B/.build/release/thunderbench local $A/clips/ES2004a.wav --fast --events local-fast.jsonl
python3 -I $B/asr-compare.py $A/clips/ES2004a-ref.json openai=openai.jsonl local-fast=local-fast.jsonl
```

這次的花費：OpenAI 約 0.36 美元（轉錄 1,200 秒，加上整句定稿的翻譯）。
