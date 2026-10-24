// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "relay-runner",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [
        .library(name: "RelayRemoteProtocol", targets: ["RelayRemoteProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.3"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0"),
    ],
    targets: [
        .target(
            name: "RelayRemoteProtocol",
            path: "Sources/RelayRemoteProtocol"
        ),
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
        .executableTarget(
            name: "relay-remote-shell",
            path: "Sources/relay-remote-shell"
        ),
        .testTarget(
            name: "RelayRemoteShellTests",
            dependencies: [.target(name: "relay-remote-shell")],
            path: "tests/RelayRemoteShellTests"
        ),
        .testTarget(
            name: "RelayRemoteProtocolTests",
            dependencies: [.target(name: "RelayRemoteProtocol")],
            path: "tests/RelayRemoteProtocolTests",
            resources: [.copy("Vectors")]
        ),
        .testTarget(
            name: "RelayRunnerTests",
            dependencies: [
                .target(name: "relay-runner"),
                .target(name: "relay-actions-mcp"),
                .target(name: "relay-orchestrator-mcp"),
                .target(name: "relay-vision-mcp"),
            ],
            path: "tests/RelayRunnerTests"
        ),
    ]
)
