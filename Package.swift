// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "relay-runner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.3"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "relay-runner",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
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
            name: "relay-vision-mcp",
            path: "Sources/relay-vision-mcp"
        ),
        .executableTarget(
            name: "relay-orchestrator-mcp",
            path: "Sources/relay-orchestrator-mcp"
        ),
        .testTarget(
            name: "RelayRunnerTests",
            dependencies: [
                .target(name: "relay-runner"),
                .target(name: "relay-vision-mcp"),
            ],
            path: "tests/RelayRunnerTests"
        ),
    ]
)
