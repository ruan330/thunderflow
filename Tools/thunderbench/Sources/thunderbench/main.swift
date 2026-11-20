import Foundation

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

switch arguments.positional.first {
case "check":
    try await checkModels()
case "synth":
    try synthesize(arguments)
case "translate":
    try await translate(arguments)
case "analyze":
    try analyze(arguments)
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
          thunderbench analyze <translate 的輸出資料夾> [--terms <terms.json> --name keynote]
              分析譯文：簡體或繁體、中國大陸用語、術語與數字的正確率。
        """)
}
