// swift-tools-version: 6.2
import PackageDescription

// ThunderKit：ThunderFlow 的所有邏輯都在這裡，App target 只負責畫面與組裝。
// v1 不依賴任何第三方套件（DESIGN.md 決策 D4）。請不要在這裡加入 dependencies。
let package = Package(
    name: "ThunderKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ThunderCore", targets: ["ThunderCore"]),
        .library(name: "ThunderAudio", targets: ["ThunderAudio"]),
        .library(name: "ThunderSession", targets: ["ThunderSession"]),
        .library(name: "ThunderEngines", targets: ["ThunderEngines"]),
        .library(name: "ThunderUI", targets: ["ThunderUI"]),
    ],
    targets: [
        .target(name: "ThunderCore"),
        .target(name: "ThunderAudio", dependencies: ["ThunderCore"]),
        .target(name: "ThunderSession", dependencies: ["ThunderCore", "ThunderAudio"]),
        // 即時字幕引擎的各個部分：停頓偵測、切段、轉錄連線、翻譯排程。不依賴 ThunderAudio。
        .target(name: "ThunderEngines", dependencies: ["ThunderCore"]),

        // 每個畫面的狀態與邏輯（不含畫面本身），所以 `swift test` 測得到介面行為。
        .target(name: "ThunderUI", dependencies: ["ThunderCore", "ThunderSession"]),

        // 測試工具：合成音訊、腳本引擎、效能預算等。不隨 App 出貨。
        .target(name: "ThunderTestKit", dependencies: ["ThunderCore", "ThunderAudio", "ThunderEngines"]),

        .testTarget(name: "ThunderTestKitTests", dependencies: ["ThunderTestKit"]),
        .testTarget(name: "ThunderCoreTests", dependencies: ["ThunderCore", "ThunderTestKit"]),
        .testTarget(name: "ThunderAudioTests", dependencies: ["ThunderAudio", "ThunderTestKit"]),
        .testTarget(name: "ThunderSessionTests", dependencies: ["ThunderSession", "ThunderTestKit"]),
        .testTarget(name: "ThunderEnginesTests", dependencies: ["ThunderEngines", "ThunderTestKit"]),
        .testTarget(name: "ThunderUITests", dependencies: ["ThunderUI", "ThunderTestKit"]),
    ]
)
