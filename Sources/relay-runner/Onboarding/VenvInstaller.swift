import Foundation
import Observation

/// Drives the Python venv bootstrap from inside the app, by invoking
/// `relay-bridge --venv-only` and streaming its output. Reusing the
/// shell script (rather than reimplementing in Swift) keeps the
/// onboarding flow on the same battle-tested path that interactive
/// `/relay-bridge` sessions use, including Homebrew auto-install,
/// Python version bounds, and dep-import re-checks.
@Observable
final class VenvInstaller {

    enum Status: Equatable {
        /// Not started yet — entered when the onboarding step is reached.
        case idle
        /// Installer is running. `message` is the most recent line
        /// emitted by relay-bridge; surface it as live status text.
        case running(message: String)
        /// Bootstrap finished cleanly; venv exists and deps import.
        case succeeded
        /// Bootstrap exited non-zero or failed to launch. The message
        /// is human-readable; relay-bridge logs the underlying detail
        /// to stdout/stderr (visible in Console).
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored
    private var process: Process?

    @ObservationIgnored
    private var outputPipe: Pipe?

    /// True when a venv exists at the canonical bundled path with deps
    /// installed. Cheap filesystem check — same logic relay-bridge uses
    /// to decide whether to skip its own bootstrap. Used to short-circuit
    /// the onboarding step on second-run-with-already-set-up.
    static var alreadyInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: bundledVenvPython)
    }

    /// Begin the bootstrap if it isn't already running. Idempotent —
    /// safe to call from `.onAppear` even if the user navigates back
    /// and forward across the step.
    func install() {
        if case .running = status { return }
        guard let scriptPath = relayBridgeScriptPath() else {
            status = .failed(message: "Couldn't locate relay-bridge in the app bundle.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)
        proc.arguments = ["--venv-only"]
        // Inherit env (PATH for Homebrew etc.) but null stdin so any
        // stray prompts don't hang the install indefinitely.
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            // relay-bridge can emit multi-line bursts (e.g. pip output).
            // Show the most recent non-empty line as the live message —
            // the full transcript still goes to Console via the inherited
            // stdout/stderr fds when the user runs from a terminal.
            let lastLine = chunk
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? ""
            guard !lastLine.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .running = self.status {
                    self.status = .running(message: lastLine)
                }
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                if proc.terminationStatus == 0 {
                    self.status = .succeeded
                } else {
                    self.status = .failed(
                        message: "Setup exited with code \(proc.terminationStatus). See Console.app for details."
                    )
                }
            }
        }

        process = proc
        status = .running(message: "Starting setup…")

        do {
            try proc.run()
        } catch {
            self.process = nil
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            status = .failed(message: "Couldn't launch setup: \(error.localizedDescription)")
        }
    }

    // MARK: - Path resolution

    /// Bundled venv interpreter path (Contents/SharedSupport/services/.venv).
    private static var bundledVenvPython: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/services/.venv/bin/python3")
            .path
    }

    /// Resolve the relay-bridge script. Prefer the bundled copy at
    /// Contents/SharedSupport/scripts/relay-bridge; fall back to the
    /// repo's scripts/ dir for `swift run`-style local iteration.
    private func relayBridgeScriptPath() -> String? {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-bridge")
            .path
        if fm.isExecutableFile(atPath: bundled) { return bundled }
        let repoLocal = fm.currentDirectoryPath + "/scripts/relay-bridge"
        if fm.isExecutableFile(atPath: repoLocal) { return repoLocal }
        return nil
    }
}
