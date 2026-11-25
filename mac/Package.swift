// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NTSBar",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "NTSBar", path: "Sources")]
)
