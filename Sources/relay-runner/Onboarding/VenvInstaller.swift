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
        /// `progress` is 0.0–1.0 when relay-bridge has emitted a
        /// `RELAY_PROGRESS:` marker, or nil if the bar should stay
        /// indeterminate (we haven't seen one yet).
        case running(message: String, progress: Double?)
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

    /// Last progress fraction we surfaced to the UI. Tracked separately
    /// from `status` so out-of-order or repeated pip "Collecting" lines
    /// can never make the bar go backwards (jittery progress is worse
    /// than no progress).
    @ObservationIgnored
    private var lastProgress: Double = 0

    /// Each pip "Collecting <pkg>" line during the dep install phase
    /// bumps the bar by this much, capped at `collectingCapPercent`.
    /// That's where the perceived "hang" lives — pip goes silent for
    /// 5–15s per wheel download, so making the bar tick per package
    /// is what keeps the install feeling alive. Cap stops short of
    /// the 80% phase marker for the speech-model download so the bar
    /// has somewhere to go when that next phase starts.
    private let collectingTickPercent: Double = 0.02
    private let collectingCapPercent: Double = 0.78

    /// True when every runtime dependency a session needs is on disk:
    /// the venv interpreter, the Kokoro speech-model files, AND the
    /// Claude Code CLI. relay-bridge runs the install path if any one
    /// is missing, so the SwiftUI must check the same union —
    /// otherwise onboarding's pythonSetup would short-circuit to
    /// .succeeded while a missing piece still needed installing, and
    /// the user would discover it only when starting a session.
    static var alreadyInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: userVenvPython)
            && fm.fileExists(atPath: kokoroModelPath)
            && fm.fileExists(atPath: kokoroVoicesPath)
            && fm.isExecutableFile(atPath: claudeCLIPath)
    }

    /// Match what tts_worker.py:_find_kokoro_model() looks for and what
    /// relay-bridge writes into during the install.
    private static var kokoroModelPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/kokoro/kokoro-v1.0.onnx")
    }
    private static var kokoroVoicesPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/kokoro/voices-v1.0.bin")
    }
    /// claude.ai/install.sh symlinks the Claude Code binary here. Match
    /// the same path relay-bridge's CLAUDE_CLI_OK gate inspects.
    private static var claudeCLIPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/bin/claude")
    }

    /// Begin the bootstrap if it isn't already running. Idempotent —
    /// safe to call from `.onAppear` even if the user navigates back
    /// and forward across the step.
    func install() {
        if case .running = status { return }
        if case .succeeded = status { return }
        // Venv is already healthy — short-circuit to succeeded so the
        // onboarding step's `onChange(of: status)` handler fires the
        // auto-advance, instead of leaving the UI parked on the idle
        // "Preparing…" spinner forever (the original bug: install() was
        // gated by the same alreadyInstalled check on the caller side,
        // so on a re-run with a healthy venv nothing ever advanced
        // status off .idle and the screen sat stuck).
        if Self.alreadyInstalled {
            status = .succeeded
            return
        }
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
            // Walk every line in order so structured `RELAY_PROGRESS:`
            // markers and informational lines both update state, then
            // pick the most recent non-empty informational line as the
            // visible message. The full transcript still goes to Console
            // via the inherited stdout/stderr fds when run from a terminal.
            let lines = chunk
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.consume(lines: lines)
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
        // Retry must start from 0% even if a prior attempt got partway
        // through — reset before kicking off the new subprocess.
        lastProgress = 0
        status = .running(message: "Starting setup…", progress: nil)

        do {
            try proc.run()
        } catch {
            self.process = nil
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            status = .failed(message: "Couldn't launch setup: \(error.localizedDescription)")
        }
    }

    // MARK: - Output parsing

    /// Apply a batch of output lines to `status`. Must run on the main
    /// queue — caller dispatches.
    ///
    /// Two kinds of lines drive the bar:
    ///   1. `RELAY_PROGRESS:<percent>:<label>` — explicit phase markers
    ///      emitted by relay-bridge. Set the bar to that percent (clamped
    ///      monotonic) and adopt the label as the visible message.
    ///   2. `Collecting <pkg>` — pip download phase signal. Each one
    ///      bumps the bar by `collectingTickPercent` so the user sees
    ///      motion during the otherwise-silent download. Capped so we
    ///      never overshoot the next phase marker.
    /// Anything else updates the visible message only.
    private func consume(lines: [String]) {
        guard case .running(let currentMessage, _) = status else { return }
        var message = currentMessage
        for line in lines {
            if let marker = parseProgressMarker(line) {
                lastProgress = max(lastProgress, marker.percent / 100.0)
                message = marker.label
            } else if line.hasPrefix("Collecting ") {
                let next = min(
                    collectingCapPercent,
                    lastProgress + collectingTickPercent
                )
                lastProgress = max(lastProgress, next)
                message = line
            } else {
                message = line
            }
        }
        status = .running(message: message, progress: lastProgress > 0 ? lastProgress : nil)
    }

    /// Parse a `RELAY_PROGRESS:<percent>:<label>` marker, or nil if the
    /// line isn't one. Tolerant of malformed percent values (clamped
    /// 0–100) so a typo in the bash script can't crash the installer.
    private func parseProgressMarker(_ line: String) -> (percent: Double, label: String)? {
        let prefix = "RELAY_PROGRESS:"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let percentStr = String(rest[..<colon])
        let label = String(rest[rest.index(after: colon)...])
        guard let raw = Double(percentStr) else { return nil }
        let clamped = min(100, max(0, raw))
        return (clamped, label)
    }

    // MARK: - Path resolution

    /// Path the venv-managed Python interpreter is expected to live at,
    /// kept in sync with `relay-bridge`'s `$SERVICES_DIR/.venv/bin/python3`.
    /// Lives under `~/Library/Application Support/relay-runner` (not in
    /// the .app bundle) so non-admin users — who can't write to a
    /// /Applications-installed bundle owned by root — can still get a
    /// working venv.
    private static var userVenvPython: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("relay-runner/services/.venv/bin/python3")
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
