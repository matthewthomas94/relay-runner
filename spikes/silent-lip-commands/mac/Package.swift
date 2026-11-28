// swift-tools-version: 5.9
import PackageDescription

// Spike-only tool: streams per-frame lip geometry from the Mac camera as JSONL.
// Not part of the relay-runner product package on purpose.
let package = Package(
    name: "LipCapture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LipCapture", path: "Sources/LipCapture"),
    ]
)
