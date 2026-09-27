import Foundation

/// Claude Code install discovery and Relay's Claude readiness.
///
/// Relay Runner is subscription-only, so Claude is ready only when
/// services/claude_subscription.py verifies that a launch would use the
/// user's Claude.ai subscription. A keychain login or `claude auth status`
/// reporting `loggedIn` is not enough: an API key, gateway or cloud route can
/// take precedence. The gate runs the CLI, so it is slow; polling UIs read
/// `ClaudeSubscriptionMonitor`'s cached result and ask it to recheck.
enum ClaudeAuth {

    static let notInstalledMessage =
        "Claude Code isn't installed. Choose Redo Onboarding\u{2026} in Settings to set it up, then sign in with your Claude.ai subscription account."

    /// Install locations checked before asking a shell: the claude.ai
    /// installer symlink, then Homebrew on Apple silicon and Intel.
    static var candidatePaths: [String] {
        [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    /// The Claude CLI that setup, sign-in and launch share, or nil when none
    /// is installed. npm and custom installs are found through the launch
    /// shell (npm global prefix, then PATH after the profile loads).
    static func resolveBinary(
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        shellLookup: () -> String? = { ProcessManager.lookUpClaudeInLaunchShell() }
    ) -> String? {
        if let path = candidatePaths.first(where: isExecutable) {
            return path
        }
        guard let found = shellLookup(), found.hasPrefix("/"), isExecutable(found) else {
            return nil
        }
        return found
    }

    /// True once the subscription gate has verified Claude. Cached; use
    /// `AgentAuth.refreshReadiness` to recheck.
    static var isAuthenticated: Bool {
        ClaudeSubscriptionMonitor.shared.latest?.isVerified == true
    }

    /// Installed, then verified by the subscription gate. Blocking.
    static func readiness(workingDirectory: String) -> ProcessManager.ClaudeSubscriptionCheck {
        guard let binary = resolveBinary() else {
            return .unavailable(notInstalledMessage)
        }
        return ProcessManager.checkClaudeSubscription(
            agentBinary: binary,
            workingDirectory: workingDirectory
        )
    }

    /// `claude auth login` exits on its own, unlike `claude /login`, which
    /// opens a full interactive session. `--claudeai` picks subscription
    /// sign-in over Console; the gate still rechecks the account's plan.
    static func loginCommand(claudePath: String) -> String {
        "echo '[Relay Runner] Sign in with the Claude.ai account that has your Pro, Max, Team or Enterprise subscription. Relay Runner does not use Anthropic Console or API billing.'; "
            + "'\(claudePath)' auth login --claudeai; "
            + "echo ''; echo '[Relay Runner] Return to Relay Runner to finish setup. You can close this window.'"
    }

    /// Open Terminal.app and run `claude auth login` in it. Returns once
    /// the AppleScript dispatch is fired — the user completes the login
    /// flow on their own time, and onboarding reruns the subscription gate
    /// to detect completion.
    @discardableResult
    static func openLoginInTerminal() -> Bool {
        let claude = resolveBinary() ?? candidatePaths[0]
        let script = """
        tell application "Terminal"
            activate
            do script "\(loginCommand(claudePath: claude))"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
    }
}

/// Caches Relay's Claude subscription gate. Every refresh is answered, on the
/// main thread, with a check that started after the caller asked; checks run
/// off the main thread, one at a time, and callers that arrive during one
/// share the next.
final class ClaudeSubscriptionMonitor {
    static let shared = ClaudeSubscriptionMonitor()

    private let check: (String) -> ProcessManager.ClaudeSubscriptionCheck
    private let runInBackground: (@escaping () -> Void) -> Void
    private(set) var latest: ProcessManager.ClaudeSubscriptionCheck?
    private var running = false
    private var waiting: [(ProcessManager.ClaudeSubscriptionCheck) -> Void] = []

    init(
        check: @escaping (String) -> ProcessManager.ClaudeSubscriptionCheck = {
            ClaudeAuth.readiness(workingDirectory: $0)
        },
        runInBackground: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        }
    ) {
        self.check = check
        self.runInBackground = runInBackground
    }

    /// Call on the main thread.
    func refresh(
        workingDirectory: String,
        completion: @escaping (ProcessManager.ClaudeSubscriptionCheck) -> Void
    ) {
        waiting.append(completion)
        startIfIdle(workingDirectory: workingDirectory)
    }

    private func startIfIdle(workingDirectory: String) {
        guard !running, !waiting.isEmpty else { return }
        running = true
        let callers = waiting
        waiting = []
        runInBackground { [self] in
            let result = check(workingDirectory)
            DispatchQueue.main.async { [self] in
                latest = result
                running = false
                callers.forEach { $0(result) }
                startIfIdle(workingDirectory: workingDirectory)
            }
        }
    }
}

enum CodexAuth {
    static var codexBinaryPath: String {
        ProcessManager.resolveAgentBinary("codex", target: .codex)
    }

    static var isAuthenticated: Bool {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".codex/auth.json")
        return FileManager.default.fileExists(atPath: path)
    }

    @discardableResult
    static func openLoginInTerminal() -> Bool {
        let codex = codexBinaryPath
        let script = """
        tell application "Terminal"
            activate
            do script "'\(codex)' login; echo ''; echo '[Relay Runner] Codex sign-in complete — you can close this window.'"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
    }
}

enum AgentAuth {
    static func isAuthenticated(for provider: GeneralConfig.AgentProvider) -> Bool {
        switch provider {
        case .codex: return CodexAuth.isAuthenticated
        case .claude: return ClaudeAuth.isAuthenticated
        }
    }

    /// Recheck readiness, then call back on the main thread with the reason
    /// the provider isn't ready (nil when it is, or when there is no detail).
    /// Codex's check is a cheap file test, so it answers immediately.
    static func refreshReadiness(
        for provider: GeneralConfig.AgentProvider,
        workingDirectory: String,
        completion: @escaping (String?) -> Void
    ) {
        switch provider {
        case .codex:
            completion(nil)
        case .claude:
            ClaudeSubscriptionMonitor.shared.refresh(workingDirectory: workingDirectory) {
                completion($0.message)
            }
        }
    }

    @discardableResult
    static func openLoginInTerminal(for provider: GeneralConfig.AgentProvider) -> Bool {
        switch provider {
        case .codex:
            return CodexAuth.openLoginInTerminal()
        case .claude:
            return ClaudeAuth.openLoginInTerminal()
        }
    }
}
