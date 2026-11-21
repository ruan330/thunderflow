# 合成語音資料集

用 macOS 的 `say` 把這裡的稿子唸成音檔，給 M0 實驗與之後的回歸測試使用。

- 稿子是為了測試而寫的，**內容是虛構的**（產品名稱、數字、公司都只是為了涵蓋術語與數字的辨識），不代表任何真實的產品資訊。
- 一行一句，`#` 開頭的行是註解。每句分別合成再接起來，所以每句的起訖時間精確已知。
- 音檔不進 repo（輸出到 `Benchmarks/data/`，已列入 .gitignore）。重新產生：

```sh
cd Tools/thunderbench && swift build -c release
.build/release/thunderbench synth ../../Benchmarks/synthetic/keynote.txt --out ../../Benchmarks/data/keynote --voice Samantha
.build/release/thunderbench synth ../../Benchmarks/synthetic/lecture.txt --out ../../Benchmarks/data/lecture --voice Daniel
.build/release/thunderbench synth ../../Benchmarks/synthetic/meeting.txt --out ../../Benchmarks/data/meeting --voice Rishi
.build/release/thunderbench synth ../../Benchmarks/synthetic/names.txt --out ../../Benchmarks/data/names --voice Samantha --rate 170
```

- `terms.json`：每份稿子裡要檢查的術語，以及可以接受的台灣繁體中文譯法。
- `names.txt`：難唸的產品名稱與一個虛構的人名，用來測試關鍵詞提示的效果（M0b）。
- `keywords-keynote.txt`、`keywords-names.txt`：給轉錄模型的關鍵詞（`keywords`），一行一個。

