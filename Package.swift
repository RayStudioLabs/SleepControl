// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SleepControl",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SleepControl",
            path: "Sources/SleepControl",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(name: "SleepControlTests", dependencies: ["SleepControl"])
    ]
)
