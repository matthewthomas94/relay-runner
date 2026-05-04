// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "relay-runner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "relay-runner",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/relay-runner",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "relay-actions-mcp",
            path: "Sources/relay-actions-mcp"
        ),
        .executableTarget(
            name: "relay-orchestrator-mcp",
            path: "Sources/relay-orchestrator-mcp"
        ),
    ]
)
