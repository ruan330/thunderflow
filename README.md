# ThunderFlow（雷霆）

macOS 原生的即時翻譯與錄音 App：聽英文演講、課程或線上會議時，即時顯示英文逐字稿與台灣繁體中文翻譯，同時把整場錄下來，結束後留下錄音、中英逐字稿與摘要。

*An open-source, native macOS app for live English → Traditional Chinese (Taiwan) captions with full local recording. Early development: a first developer build runs, but it is not ready for real use.*

> **狀態：開發中。** 已經有第一個可以試用的開發版（`make run`）：即時字幕、錄音、中英逐字稿、摘要與過去錄音的瀏覽都跑得起來，但麥克風與系統音訊的擷取還沒有經過完整的實機驗證，也還沒有簽章與公證的發行版。進度見 [DESIGN.md](DESIGN.md) 第 12.1 節。

## 它要做的事

1. **即時翻譯**：英文逐字稿與繁中翻譯同時顯示。
2. **錄音**：完整保存整場錄音，當機或斷網都不遺失。
3. **中英逐字稿**：中英對照、標有時間。
4. **摘要**：結束後自動產生摘要與章節。

設計上的幾個選擇：

- **自備 API Key（BYOK）**：使用你自己的 OpenAI API Key，存在 macOS 的 Keychain。
- **資料留在本機**：每一場是一個看得到的資料夾（錄音、逐字稿、摘要），不使用資料庫，沒有遙測。只有音訊與逐字稿文字會送到你設定的 AI 服務。
- **不依賴第三方套件**，只用 Apple SDK。
- **測試先行**：每個里程碑先提交會失敗的測試，再實作。效能預算也寫成測試。

完整的設計、決策與理由在 [DESIGN.md](DESIGN.md)。

## 建置與測試

需要 macOS 26 以上、Xcode 26 以上（Swift 6.2 以上）。所有邏輯都在 `Packages/ThunderKit`，不需要開 Xcode：

```sh
make run         # 打包成 build/ThunderFlow.app 並開啟（開發版，ad-hoc 簽章）
make test        # 單元、整合、當機安全、30 分鐘記憶體測試
make test-tsan   # Thread Sanitizer
make test-perf   # 效能預算（release 模式）
```

每個測試的名稱列在 [TESTS.md](TESTS.md)。

## 這個 repo 裡有什麼

| 路徑 | 內容 |
|---|---|
| [DESIGN.md](DESIGN.md) | 設計文件：範圍、架構、測試計畫、決策紀錄、里程碑 |
| `Packages/ThunderKit` | 全部的邏輯：錄音管線、場次資料夾、日誌、當機復原 |
| `Tools/thunderbench` | 探索 AI 服務 API 用的實驗工具與分析腳本 |
| `Benchmarks/results` | 實驗報告：[即時翻譯連線](Benchmarks/results/m0-report.md)、[純轉錄連線加文字模型](Benchmarks/results/m0b-report.md) |
| `Benchmarks/fixtures` | 實驗時錄下的 API 事件，給引擎的測試重播 |
| [CLAUDE.md](CLAUDE.md) | 開發規範 |

## 授權

[MIT](LICENSE)
