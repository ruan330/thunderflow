// swift-tools-version: 6.2
import PackageDescription

// thunderbench：M0 實驗用的命令列工具（探索 OpenAI 即時翻譯 API 的實際行為）。
// 這是探索用的程式，不是產品程式碼；之後會改寫成正式的 benchmark 工具。不依賴任何第三方套件。
let package = Package(
    name: "thunderbench",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "thunderbench", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
