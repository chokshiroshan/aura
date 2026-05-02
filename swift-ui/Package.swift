// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aura",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Aura",
            path: "Sources/Aura",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
