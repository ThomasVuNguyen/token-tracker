// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "TokenTracker", dependencies: ["UsageCore"]),
    ]
)
