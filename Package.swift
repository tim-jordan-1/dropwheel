// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dropwheel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DropwheelCore", swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .executableTarget(name: "dropwheel-cli", dependencies: ["DropwheelCore"]),
        .executableTarget(name: "Dropwheel", dependencies: ["DropwheelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
