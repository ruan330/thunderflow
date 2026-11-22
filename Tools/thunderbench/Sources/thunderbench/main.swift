import Foundation

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

switch arguments.positional.first {
case "check":
    try await checkModels()
case "synth":
    try synthesize(arguments)
case "translate":
    try await translate(arguments)
case "transcribe":
    try await transcribe(arguments)
case "analyze":
    try analyze(arguments)
case "live":
    try await live(arguments)
default:
    fail(
        """
        用法：
          thunderbench check
              確認 API Key 可用，列出相關模型（免費）。
          thunderbench synth <稿子.txt> --out <輸出名稱> [--voice Samantha] [--rate 175] [--pause-ms 350]
              用 macOS 的 say 把稿子（一行一句）合成為 24 kHz WAV，並記下每句的起訖時間。
          thunderbench translate <音檔.wav> --out <資料夾> [--language zh] [--chunk-ms 200] [--speed 1]
                                 [--no-source] [--noise-reduction none|near_field|far_field]
                                 [--loop-minutes N] [--preconnect-seconds N] [--close-wait 20]
              把音檔串流到 gpt-realtime-translate，錄下所有事件與時間（會產生 API 費用）。
          thunderbench transcribe <音檔.wav> --out <資料夾> [--delay minimal|low|medium|high|xhigh] [--commit none|interval:<秒>|silence:<毫秒>|plan:<檔案>]
                                  [--max-turn <秒>] [--keywords <一行一個的檔案>] [--prompt <文字>] [--languages en,zh-tw]
                                  [--chunk-ms 200] [--speed 1] [--loop-minutes N] [--hold-minutes N]
              把音檔串流到純轉錄的連線（gpt-live-transcribe），錄下所有事件與時間（會產生 API 費用）。
              加 --no-audio（可搭配 --session-json）只送設定、不送音訊，用來試哪些設定會被接受（免費）。
          thunderbench live <音檔.wav> [--seconds N] [--keywords <一行一個的檔案>] [--title <標題>] [--no-provisional] [--sentences] [--sentence-provisional] [--provisional-words 3] [--provisional-interval 1] [--provisional-first-words 2] [--service-tier priority] [--delay low] [--quiet]
                            [--sentences] [--events <事件.jsonl>]
              用正式的引擎（TranscribeTranslateEngine）以即時速度處理音檔，印出每個字幕事件與時間（會產生 API 費用）。
              --sentences 用整句模式（和 App 一樣）。--events 把每個事件（含英文的增量）寫成一行 JSON，給分析腳本用。
          thunderbench analyze <translate 的輸出資料夾> [--terms <terms.json> --name keynote]
              分析譯文：簡體或繁體、中國大陸用語、術語與數字的正確率。
        """)
}
