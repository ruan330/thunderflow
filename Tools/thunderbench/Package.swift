// swift-tools-version: 6.2
import PackageDescription

// thunderbench：M0 實驗用的命令列工具（探索 OpenAI 即時翻譯 API 的實際行為）。
// 這是探索用的程式，不是產品程式碼；之後會改寫成正式的 benchmark 工具。不依賴任何第三方套件。
// `live` 指令用的是正式的引擎（Packages/ThunderKit），所以依賴同一個 repo 裡的那個 package。
let package = Package(
    name: "thunderbench",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/ThunderKit")],
    targets: [
        .executableTarget(
            name: "thunderbench",
            dependencies: [
                .product(name: "ThunderCore", package: "ThunderKit"),
                .product(name: "ThunderEngines", package: "ThunderKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
