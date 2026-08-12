// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tracki",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Tracki",
            path: "Tracki",
            // Not Swift sources — SPM errors on unhandled files under the target path.
            // `Resources/` is copied into the .app by the Makefile's `bundle` rule instead,
            // so the app reads it via Bundle.main rather than an SPM resource bundle.
            exclude: ["Info.plist", "AppIcon.icns", "Resources"]
        )
    ]
)
