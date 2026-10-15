// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoltPair",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BoltPair", path: "Sources/BoltPair"),
    ]
)
