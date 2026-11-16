import AppKit
import Darwin
import Observation
import SwiftTerm

/// How an in-app provider sign-in ended.
enum ProviderLoginOutcome: Equatable {
    /// The login command exited; nil when a signal ended it.
    case exited(Int32?)
    /// The person canceled and Relay Runner stopped the login command.
    case cancelled
}

/// One provider sign-in that onboarding runs inside Relay Runner (RR-513).
protocol ProviderLoginRunning: AnyObject {
    var provider: GeneralConfig.AgentProvider { get }
    var terminalView: NSView { get }
    /// The latest sign-in page the login command printed.
    var signInURL: String? { get }
    var isCancelling: Bool { get }
    /// RR-514: called whenever sign-in sends the person to the browser, so
    /// onboarding can step aside first. `open` is nil when the login command
    /// opened its sign-in page itself; otherwise calling it opens the page.
    var onBrowserHandoff: ((_ open: (() -> Void)?) -> Void)? { get set }
    /// Throws when the embedded terminal cannot start the command.
    /// `onExit` is called once, on the main thread.
    func start(onExit: @escaping (ProviderLoginOutcome) -> Void) throws
    func cancel()
    func openSignInURL()
    func copySignInURL()
}

/// The provider's own login command, run through the launch shell so the
/// user's profile PATH applies (npm and custom installs), as Start Session
/// does. `exec` makes the login process the PTY's process-group leader, so
/// cancelling reaches it and anything it started.
struct ProviderLoginCommand: Equatable {
    var executable: String
    var arguments: [String]
    /// Printed into the terminal before the command starts.
    var banner: String

    static func claude(binary: String) -> ProviderLoginCommand {
        // `auth login` exits on its own, unlike `/login`; `--claudeai` picks
        // subscription sign-in over Console. The gate still rechecks the plan.
        launchShell(
            "exec \(ProcessManager.shellQuoted(binary)) auth login --claudeai",
            banner: "[Relay Runner] Sign in with the Claude.ai account that has your Pro, Max, Team or Enterprise subscription. Relay Runner does not use Anthropic Console or API billing."
        )
    }

    static func codex(binary: String) -> ProviderLoginCommand {
        // The same ChatGPT-only login the Start Session gate runs.
        launchShell(
            "exec \(ProcessManager.shellQuoted(binary)) -c 'forced_login_method=\"chatgpt\"' login",
            banner: "[Relay Runner] Sign in with the ChatGPT account that has your subscription. Relay Runner does not use OpenAI API billing."
        )
    }

    static func forProvider(_ provider: GeneralConfig.AgentProvider) -> ProviderLoginCommand {
        switch provider {
        case .claude:
            return claude(binary: ClaudeAuth.resolveBinary() ?? ClaudeAuth.candidatePaths[0])
        case .codex:
            return codex(binary: CodexAuth.codexBinaryPath)
        }
    }

    private static func launchShell(_ login: String, banner: String) -> ProviderLoginCommand {
        let script = [
            ProcessManager.inheritedHostSessionScrub,
            ProcessManager.shellProfileSource(),
            login,
        ].joined(separator: "\n")
        return ProviderLoginCommand(executable: "/bin/bash", arguments: ["-c", script], banner: banner)
    }
}

/// Picks sign-in links out of raw PTY output: OSC 8 hyperlinks and plain
/// `http(s)` URLs on completed lines, so a link the terminal wraps across rows
/// still comes through whole. Local callback servers are not sign-in pages.
struct ProviderLoginURLScanner {
    private var pending: [UInt8] = []
    private static let pendingLimit = 64 * 1024

    /// Returns the last sign-in URL found in the lines `bytes` completed.
    mutating func consume<S: Sequence>(_ bytes: S) -> String? where S.Element == UInt8 {
        var found: String?
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D {
                if let url = Self.lastURL(in: String(decoding: pending, as: UTF8.self)) {
                    found = url
                }
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < Self.pendingLimit {
                pending.append(byte)
            }
        }
        return found
    }

    static func lastURL(in line: String) -> String? {
        var candidates: [String] = []
        for match in line.matches(of: #/\x1B\]8;[^;\x07\x1B]*;([^\x07\x1B]+)/#) {
            candidates.append(String(match.1))
        }
        let plain = line
            .replacing(#/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/#, with: "")
            .replacing(#/\x1B\[[0-?]*[ -\/]*[@-~]/#, with: "")
            .replacing(#/\x1B[@-_]/#, with: "")
        for match in plain.matches(of: #/https?:\/\/[^\s<>"'`]+/#) {
            candidates.append(String(match.0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}'\"")))
        }
        return candidates.last(where: isSignInURL)
    }

    private static func isSignInURL(_ candidate: String) -> Bool {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

/// Runs a provider's login command in a SwiftTerm PTY that onboarding shows
/// in place. Nothing goes through Terminal.app or AppleScript.
@Observable
final class ProviderLoginTerminal: ProviderLoginRunning, TerminalViewDelegate, LocalProcessDelegate {
    let provider: GeneralConfig.AgentProvider
    private(set) var signInURL: String?
    private(set) var isCancelling = false

    @ObservationIgnored private let command: ProviderLoginCommand
    @ObservationIgnored private let view: RelayTerminalView
    @ObservationIgnored private var localProcess: LocalProcess!
    @ObservationIgnored private var scanner = ProviderLoginURLScanner()
    @ObservationIgnored private var onExit: ((ProviderLoginOutcome) -> Void)?
    @ObservationIgnored private var processGroup: pid_t = 0
    @ObservationIgnored private let killGracePeriod: TimeInterval
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let copyString: (String) -> Void
    @ObservationIgnored var onBrowserHandoff: ((_ open: (() -> Void)?) -> Void)?

    init(
        provider: GeneralConfig.AgentProvider,
        command: ProviderLoginCommand,
        killGracePeriod: TimeInterval = 2,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        copyString: @escaping (String) -> Void = { string in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    ) {
        self.provider = provider
        self.command = command
        self.killGracePeriod = killGracePeriod
        self.openURL = openURL
        self.copyString = copyString
        view = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 280))
        view.wantsLayer = true
        view.font = AppTypography.terminalGridFont(size: RelayTerminalView.baseFontSize, weight: .regular)
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = NSColor(srgbRed: 218 / 255, green: 225 / 255, blue: 234 / 255, alpha: 1)
        view.caretColor = .controlAccentColor
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // Plain URLs open on a plain click; selections copy with Cmd-C.
        view.linkReporting = .implicit
        view.linkHighlightMode = .hover
        view.terminalDelegate = self
        localProcess = LocalProcess(delegate: self)
    }

    /// Released while the login still runs (onboarding torn down): stop its
    /// process group now and reap it, so nothing is left behind.
    deinit {
        guard onExit != nil, processGroup > 0 else { return }
        Darwin.kill(-processGroup, SIGKILL)
        _ = AssistantManagedProviderProcess.reapExplicitlyStoppedChild(Int(processGroup))
    }

    convenience init(provider: GeneralConfig.AgentProvider) {
        self.init(provider: provider, command: .forProvider(provider))
    }

    var terminalView: NSView { view }
    var isRunning: Bool { localProcess.running }
    var childPID: pid_t? { processGroup > 0 ? processGroup : nil }

    func start(onExit: @escaping (ProviderLoginOutcome) -> Void) throws {
        guard self.onExit == nil else { throw EmbeddedTerminalProcessError.alreadyRunning }
        view.feed(text: command.banner + "\r\n\r\n")
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        localProcess.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: NSHomeDirectory()
        )
        guard localProcess.running, localProcess.shellPid > 0 else {
            throw EmbeddedTerminalProcessError.couldNotStart
        }
        processGroup = localProcess.shellPid
        self.onExit = onExit
    }

    /// Stops the login command and everything in its process group: SIGTERM,
    /// then SIGKILL for whatever is still there after the grace period.
    func cancel() {
        guard onExit != nil, !isCancelling, processGroup > 0 else { return }
        isCancelling = true
        let group = processGroup
        Darwin.kill(-group, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + killGracePeriod) {
            if Darwin.kill(-group, 0) == 0 {
                Darwin.kill(-group, SIGKILL)
            }
        }
    }

    func openSignInURL() {
        guard let signInURL, let url = URL(string: signInURL) else { return }
        openInBrowser(url)
    }

    private func openInBrowser(_ url: URL) {
        let open = { [openURL] in openURL(url) }
        guard let onBrowserHandoff else {
            open()
            return
        }
        onBrowserHandoff(open)
    }

    func copySignInURL() {
        guard let signInURL else { return }
        copyString(signInURL)
    }

    // MARK: LocalProcessDelegate

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard let onExit else { return }
        self.onExit = nil
        onExit(isCancelling ? .cancelled : .exited(EmbeddedTerminalSession.decodeWaitStatus(exitCode)))
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        view.feed(byteArray: slice)
        if let url = scanner.consume(slice), url != signInURL {
            let isFirstPage = signInURL == nil
            signInURL = url
            // Claude's and Codex's login commands open their first sign-in
            // page in the browser as they print it.
            if isFirstPage {
                onBrowserHandoff?(nil)
            }
        }
    }

    func getWindowSize() -> winsize {
        let terminal = view.getTerminal()
        return winsize(
            ws_row: UInt16(max(1, terminal.rows)),
            ws_col: UInt16(max(1, terminal.cols)),
            ws_xpixel: UInt16(clamping: Int(view.bounds.width)),
            ws_ypixel: UInt16(clamping: Int(view.bounds.height))
        )
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard localProcess.running else { return }
        localProcess.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard localProcess.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: localProcess.childfd, windowSize: &size)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        openInBrowser(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
