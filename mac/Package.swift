// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NTSBar",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "NTSBar", path: "Sources")]
)
