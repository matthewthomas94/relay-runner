import Foundation

// Relay Desktop: Relay Runner.app runs the bundled vercel-labs/agent-desktop
// CLI as its own child process, so macOS attributes Accessibility to Relay
// Runner rather than to Codex, Claude, Terminal, or an editor. The
// relay-desktop-mcp helper only forwards an argv over /tmp/relay_actions.sock;
// this file decides what may run and runs it.

/// Which agent-desktop invocations the hosted path accepts. Observation and
/// headless semantic actions only: physical input stays with Relay Actions,
/// pixels with Relay Vision, and the clipboard, sessions, traces and debug
/// artefacts are not exposed at all.
enum RelayDesktopCommandPolicy {
    static let allowedSubcommands: Set<String> = [
        // Observe
        "snapshot", "find", "get", "is", "list-surfaces",
        // Act on a ref (headless)
        "click", "right-click", "type", "set-value", "clear", "focus", "select",
        "toggle", "check", "uncheck", "expand", "collapse", "scroll", "scroll-to",
        // Keyboard, apps, windows, waiting, status
        "press", "launch", "list-apps", "list-windows", "list-displays",
        "focus-window", "wait", "status", "version", "skills",
    ]

    /// Flags that would switch to physical delivery, override the CLI's own
    /// safety policy, or write local artefacts.
    static let forbiddenFlags: Set<String> = [
        "--headed", "--force", "--screenshot", "--debug", "--trace", "--trace-strict",
        "--session", "--agent-id",
    ]

    enum Violation: Equatable {
        case empty
        case subcommand(String)
        case flag(String)

        var message: String {
            switch self {
            case .empty:
                return "Relay Desktop needs an agent-desktop subcommand."
            case .subcommand(let name):
                return "Relay Desktop does not run agent-desktop '\(name)'. Use a Relay Desktop tool, Relay Actions for physical input, or Relay Vision for pixels."
            case .flag(let name):
                return "Relay Desktop refuses '\(name)': it runs headless, policy-checked agent-desktop commands only."
            }
        }
    }

    static func validate(_ argv: [String]) -> Violation? {
        guard let subcommand = argv.first else { return .empty }
        guard allowedSubcommands.contains(subcommand) else { return .subcommand(subcommand) }
        for argument in argv.dropFirst() where argument.hasPrefix("--") {
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if forbiddenFlags.contains(flag) { return .flag(flag) }
        }
        return nil
    }
}

enum RelayDesktopHost {
    static let binaryName = "agent-desktop"
    static let helperName = "agent-desktop-macos-helper"
    static let pathOverrideEnvironment = "RELAY_AGENT_DESKTOP_PATH"
    static let maxOutputBytes = 16 * 1024 * 1024
    static let defaultTimeoutSeconds: TimeInterval = 60
    static let maxTimeoutSeconds: TimeInterval = 180

    /// The bundled CLI sits beside the app's own executable (Contents/MacOS in a
    /// release bundle, the SwiftPM bin directory in development). An explicit
    /// path or a package-manager install is accepted after that.
    static func binaryURL(
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        var candidates: [String] = []
        if let executableDirectory {
            candidates.append(executableDirectory.appendingPathComponent(binaryName).path)
        }
        if let override = environment[pathOverrideEnvironment], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("/opt/homebrew/bin/\(binaryName)")
        candidates.append("/usr/local/bin/\(binaryName)")
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func timeout(from arguments: [String: Any]) -> TimeInterval {
        let requested = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? defaultTimeoutSeconds
        return min(max(requested, 1), maxTimeoutSeconds)
    }

    static func perform(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let argv = arguments["argv"] as? [String], argv.allSatisfy({ !$0.isEmpty }) else {
            throw RelayHostedToolError.message("desktop requires an argv array of non-empty strings.")
        }
        if let violation = RelayDesktopCommandPolicy.validate(argv) {
            throw RelayHostedToolError.message(violation.message)
        }
        guard let binary = binaryURL() else {
            throw RelayHostedToolError.message("""
                Relay Desktop is unavailable: the bundled agent-desktop CLI was not found beside Relay Runner. \
                Reinstall Relay Runner, or set \(pathOverrideEnvironment) to an agent-desktop executable for development.
                """)
        }
        let output = try await run(binary: binary, argv: argv, timeout: timeout(from: arguments))
        return [["type": "text", "text": output]]
    }

    struct Completion {
        let stdout: Data
        let stderr: Data
        let exitStatus: Int32
        let timedOut: Bool
    }

    /// Runs one agent-desktop command and returns its stdout envelope. The CLI
    /// prints a JSON envelope with `ok: false` on every handled failure, so a
    /// non-zero exit with output is still a result for the agent to read.
    static func run(binary: URL, argv: [String], timeout: TimeInterval) async throws -> String {
        let completion = try await launch(binary: binary, argv: argv, timeout: timeout)
        if completion.stdout.count > maxOutputBytes {
            throw RelayHostedToolError.message(
                "agent-desktop \(argv[0]) produced more than \(maxOutputBytes / (1024 * 1024)) MB; narrow the snapshot with `skeleton`, `root`, or `interactive_only`."
            )
        }
        if completion.timedOut {
            throw RelayHostedToolError.message(
                "agent-desktop \(argv[0]) did not finish within \(Int(timeout)) s and was stopped. A wait or action may have been delivered; observe the app before retrying."
            )
        }
        let stdout = String(decoding: completion.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        let stderr = String(decoding: completion.stderr.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw RelayHostedToolError.message(
            "agent-desktop \(argv[0]) exited with status \(completion.exitStatus) and no result." + (stderr.isEmpty ? "" : "\n\(stderr)")
        )
    }

    static func launch(binary: URL, argv: [String], timeout: TimeInterval) async throws -> Completion {
        let process = Process()
        process.executableURL = binary
        process.arguments = argv
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        let helper = binary.deletingLastPathComponent().appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            environment["AGENT_DESKTOP_MACOS_HELPER_PATH"] = helper.path
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let timedOut = TimedOutFlag()
        // Drain both pipes on background threads from the start, so a snapshot
        // larger than the pipe buffer never stalls the CLI on a blocked write.
        // Each read returns at EOF, which Foundation delivers once the child
        // exits and the parent's write ends are closed.
        let drain = PipeDrain(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        var launchError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                launchError = error
                // The child never started, so close the write ends ourselves
                // or the drains would wait forever.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }
        let (stdoutData, stderrData) = await drain.finish()
        if let launchError {
            throw RelayHostedToolError.message("Could not start agent-desktop: \(launchError.localizedDescription)")
        }
        return Completion(
            stdout: stdoutData,
            stderr: stderrData,
            exitStatus: process.terminationStatus,
            timedOut: timedOut.value
        )
    }

    private final class TimedOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    private final class PipeDrain: @unchecked Sendable {
        private let group = DispatchGroup()
        private var stdoutData = Data()
        private var stderrData = Data()

        init(stdout: FileHandle, stderr: FileHandle) {
            group.enter()
            DispatchQueue.global().async { [self] in
                stdoutData = stdout.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async { [self] in
                stderrData = stderr.readDataToEndOfFile()
                group.leave()
            }
        }

        func finish() async -> (Data, Data) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { continuation.resume() }
            }
            return (stdoutData, stderrData)
        }
    }
}
