// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Granola",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Granola",
            path: "Sources/Granola"
        )
    ]
)
