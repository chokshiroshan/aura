// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orb",
            path: "Sources/Aura",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
