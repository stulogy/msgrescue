// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "msgrescue",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "msgrescue", path: "Sources/msgrescue")
    ]
)
