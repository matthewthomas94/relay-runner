// swift-tools-version: 5.9
import PackageDescription

// Relay Remote's transport, pairing and session logic (docs/specs/relay-remote.md,
// "iOS app"). The app target in ../RelayRemote.xcodeproj is a thin SwiftUI shell
// over this package. swift-nio-ssh and swift-nio-transport-services are pinned to
// the revisions the RR-420 transport spike read.
let package = Package(
    name: "RelayRemoteKit",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "RelayRemoteKit", targets: ["RelayRemoteKit"]),
    ],
    dependencies: [
        .package(name: "relay-runner", path: "../.."),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", revision: "149f32ffacda5770e513cb41bd175e3d6ef77ce3"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", revision: "f85ed684f4e49be63be0659b0b9773919d872f12"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "RelayRemoteKit",
            dependencies: [
                .product(name: "RelayRemoteProtocol", package: "relay-runner"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RelayRemoteKitTests",
            dependencies: [
                "RelayRemoteKit",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
