// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tracki",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Tracki",
            path: "Tracki",
            exclude: ["Info.plist"]
        )
    ]
)
