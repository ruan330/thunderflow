// swift-tools-version: 6.2
import PackageDescription

// ThunderFlow.app 的畫面與組裝。邏輯都在 Packages/ThunderKit，這裡只放 SwiftUI／AppKit 的畫面，
// 以及把各部分接起來的程式碼（DESIGN.md 5.2 節）。用 `make app` 打包成 .app，不需要開 Xcode。
let package = Package(
    name: "ThunderFlowApp",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../Packages/ThunderKit")],
    targets: [
        .executableTarget(
            name: "ThunderFlow",
            dependencies: [
                .product(name: "ThunderCore", package: "ThunderKit"),
                .product(name: "ThunderAudio", package: "ThunderKit"),
                .product(name: "ThunderSession", package: "ThunderKit"),
                .product(name: "ThunderEngines", package: "ThunderKit"),
                .product(name: "ThunderUI", package: "ThunderKit"),
            ])
    ]
)
