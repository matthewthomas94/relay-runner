import Foundation

/// RR-487: the newest `relay-rs` built in `rust/`, for tests that run its
/// subcommands. The app runs the copy in its bundle's Contents/MacOS; there is
/// no Python fallback to test instead. Nil until `cargo build` runs in rust/.
enum BuiltRelayRS {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let path: String? = {
        let modified = { (path: String) in
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        }
        return ["debug", "release", "aarch64-apple-darwin/release"]
            .map { repositoryRoot.appendingPathComponent("rust/target/\($0)/relay-rs").path }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .max { modified($0) < modified($1) }
    }()

    static let notBuilt = "relay-rs is not built; run `cargo build` in rust/"
}
