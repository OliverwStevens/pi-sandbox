// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PiSandbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PiSandbox", path: "Sources/PiSandbox")
    ]
)
