// swift-tools-version: 6.2
import PackageDescription

// 空白的 SwiftUI App：量測 ThunderFlow 的啟動時間與閒置時的記憶體時，用它當對照（DESIGN.md 9.8 節）。
// 換一台機器也能比較：比的是「ThunderFlow 比空白的 App 多了多少」。由 Scripts/measure-app.sh 打包與執行。
let package = Package(
    name: "EmptyShell",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "EmptyShell")]
)
