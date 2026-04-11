// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTerminal",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceTerminal",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/VoiceTerminal",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
