// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeServant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeServant", path: "Sources/ClaudeServant")
    ]
)
