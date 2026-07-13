import AppKit
import Observation
import SwiftTerm
import SwiftUI

protocol EmbeddedTerminalProcess: AnyObject {
    var view: NSView { get }
    var isRunning: Bool { get }
    var hasFocus: Bool { get }
    var onExit: ((Int32?) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws
    func focus()
    func terminate()
}

enum EmbeddedTerminalProcessError: LocalizedError, Equatable {
    case alreadyRunning
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A Relay Runner session is already active."
        case .couldNotStart:
            return "The embedded terminal could not start the agent process."
        }
    }
}

/// Long-lived owner for the terminal process. Workspace views only borrow the
/// hosted NSView, so hiding the overlay or switching tabs cannot end a session.
@Observable
final class EmbeddedTerminalSession {
    enum Phase: Equatable {
        case idle
        case preparing
        case running
        case external
        case ended
        case exited(Int32?)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .running, .external: return true
            case .idle, .ended, .exited, .failed: return false
            }
        }
    }

    typealias ProcessFactory = () -> EmbeddedTerminalProcess

    private(set) var phase: Phase = .idle
    private(set) var providerName = "Agent"
    private(set) var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    private(set) var terminalTitle = ""
    private(set) var presentationRevision = 0

    @ObservationIgnored private let processFactory: ProcessFactory
    @ObservationIgnored private var process: EmbeddedTerminalProcess?
    @ObservationIgnored private var exitHandler: ((Int32?) -> Void)?

    init(processFactory: @escaping ProcessFactory = { SwiftTermEmbeddedProcess() }) {
        self.processFactory = processFactory
    }

    var hostedView: NSView? { process?.view }
    var hasTerminalFocus: Bool { process?.hasFocus == true }
    var isEmbeddedProcessRunning: Bool { phase == .running && process?.isRunning == true }

    func setExitHandler(_ handler: @escaping (Int32?) -> Void) {
        exitHandler = handler
    }

    func beginPreparing(providerName: String, workingDirectory: String) throws {
        guard !phase.isActive else { throw EmbeddedTerminalProcessError.alreadyRunning }
        self.providerName = providerName
        self.workingDirectory = workingDirectory
        terminalTitle = ""
        phase = .preparing
    }

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        guard phase == .preparing else { throw EmbeddedTerminalProcessError.alreadyRunning }

        let next = processFactory()
        next.onTitle = { [weak self, weak next] title in
            guard let self, let next, self.process === next else { return }
            self.terminalTitle = title
        }
        next.onExit = { [weak self, weak next] rawStatus in
            guard let self, let next else { return }
            DispatchQueue.main.async { [weak self, weak next] in
                guard let self,
                      let next,
                      self.process === next,
                      self.phase == .running else { return }
                let exitCode = Self.decodeWaitStatus(rawStatus)
                self.phase = .exited(exitCode)
                self.exitHandler?(exitCode)
            }
        }

        process?.onExit = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = next
        presentationRevision += 1

        do {
            try next.start(launch)
            guard next.isRunning else { throw EmbeddedTerminalProcessError.couldNotStart }
            phase = .running
        } catch {
            next.onExit = nil
            next.onTitle = nil
            next.terminate()
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    func markExternal(providerName: String, workingDirectory: String) {
        self.providerName = providerName
        self.workingDirectory = workingDirectory
        terminalTitle = "Terminal.app"
        phase = .external
    }

    func markFailed(_ error: Error) {
        phase = .failed(error.localizedDescription)
    }

    func end() {
        process?.onExit = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        phase = .ended
    }

    func shutdown() {
        process?.onExit = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        presentationRevision += 1
        phase = .idle
    }

    func focus() {
        process?.focus()
    }

    func updateTitle(_ title: String) {
        terminalTitle = title
    }

    static func decodeWaitStatus(_ rawStatus: Int32?) -> Int32? {
        guard let rawStatus else { return nil }
        let signalBits = rawStatus & 0x7f
        guard signalBits == 0 else { return nil }
        return (rawStatus >> 8) & 0xff
    }
}

private final class RelayTerminalView: TerminalView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// SwiftTerm adapter with OSC 52 clipboard access denied. Explicit user copy
/// and paste still use TerminalView's normal AppKit commands.
private final class SwiftTermEmbeddedProcess: EmbeddedTerminalProcess, TerminalViewDelegate, LocalProcessDelegate {
    let terminalView: RelayTerminalView
    lazy var localProcess = LocalProcess(delegate: self)
    var onExit: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?

    init() {
        terminalView = RelayTerminalView(frame: .zero)
        terminalView.terminalDelegate = self
        terminalView.wantsLayer = true
        terminalView.font = AppTypography.terminalGridFont(size: 13, weight: .regular)

        let background = NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 14 / 255, alpha: 1)
        terminalView.nativeBackgroundColor = background
        terminalView.nativeForegroundColor = NSColor(srgbRed: 218 / 255, green: 225 / 255, blue: 234 / 255, alpha: 1)
        terminalView.caretColor = .controlAccentColor
        terminalView.layer?.backgroundColor = background.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBlock)
    }

    var view: NSView { terminalView }
    var isRunning: Bool { localProcess.running }
    var hasFocus: Bool { terminalView.hasFocus }

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        localProcess.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: Self.terminalEnvironment(),
            currentDirectory: launch.workingDirectory
        )
        guard localProcess.running else { throw EmbeddedTerminalProcessError.couldNotStart }
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func terminate() {
        localProcess.terminate()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        localProcess.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard localProcess.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: localProcess.childfd,
            windowSize: &size
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminalView.feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        winsize(
            ws_row: UInt16(max(1, terminalView.getTerminal().rows)),
            ws_col: UInt16(max(1, terminalView.getTerminal().cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode)
    }

    private static func terminalEnvironment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.map { "\($0.key)=\($0.value)" }
    }
}

final class EmbeddedTerminalHostNSView: NSView {
    private weak var installedView: NSView?

    func install(_ terminalView: NSView?) {
        guard installedView !== terminalView else { return }
        installedView?.removeFromSuperview()
        installedView = terminalView
        guard let terminalView else { return }

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self, let terminalView, self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(terminalView)
        }
    }

    func detach() {
        if installedView?.superview === self {
            installedView?.removeFromSuperview()
        }
        installedView = nil
    }
}

private struct EmbeddedTerminalRepresentable: NSViewRepresentable {
    @Bindable var session: EmbeddedTerminalSession

    func makeNSView(context: Context) -> EmbeddedTerminalHostNSView {
        let host = EmbeddedTerminalHostNSView()
        host.install(session.hostedView)
        return host
    }

    func updateNSView(_ nsView: EmbeddedTerminalHostNSView, context: Context) {
        _ = session.presentationRevision
        nsView.install(session.hostedView)
    }

    static func dismantleNSView(_ nsView: EmbeddedTerminalHostNSView, coordinator: ()) {
        nsView.detach()
    }
}

struct EmbeddedTerminalTab: View {
    @Bindable var session: EmbeddedTerminalSession
    let providerName: String
    let workingDirectory: String
    let hasActiveSession: Bool
    let onStart: () -> Void
    let onEnd: () -> Void
    let onOpenExternal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if case .failed(let message) = session.phase {
                Text(message)
                    .font(AppTypography.font(.status))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
            }
            Divider().overlay(BoardDarkSurfaceStyle.border)

            if session.hostedView != nil {
                EmbeddedTerminalRepresentable(session: session)
                    .id(session.presentationRevision)
                    .background(Color(nsColor: BoardDarkSurfaceStyle.panelFillNSColor))
            } else {
                emptyState
            }
        }
        .frame(maxWidth: WorkspaceSurfaceSizing.terminalMaxWidth, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight)
        .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius, style: .continuous)
                .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
        .environment(\.colorScheme, .dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(AppTypography.symbolFont(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(AppTypography.font(.status))
                    .foregroundStyle(.primary)
                Text(displayDirectory)
                    .font(AppTypography.monospacedFont(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if hasActiveSession {
                Button("End Session", action: onEnd)
                    .buttonStyle(.bordered)
            } else {
                Button("Open in Terminal.app", action: onOpenExternal)
                    .buttonStyle(.bordered)
                Button("Start \(providerName)", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(AppTypography.symbolFont(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run the Relay session here")
                .font(AppTypography.font(.screenTitle))
            Text(emptyStateDetail)
                .font(AppTypography.font(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch session.phase {
        case .idle: return "Ready for \(providerName)"
        case .preparing: return "Preparing \(session.providerName)"
        case .running: return session.terminalTitle.isEmpty ? "\(session.providerName) session" : session.terminalTitle
        case .external: return "\(session.providerName) in Terminal.app"
        case .ended: return "Session ended"
        case .exited(let code):
            return code.map { "Session exited (\($0))" } ?? "Session exited"
        case .failed: return "Session failed to start"
        }
    }

    private var emptyStateDetail: String {
        switch session.phase {
        case .external:
            return "This Relay session is running in Terminal.app. End it here before starting an embedded session."
        case .ended, .exited:
            return "The previous session has ended. Start again from the toolbar when you're ready."
        case .failed(let message):
            return message
        default:
            return "Starts the configured agent with Relay voice mode in this workspace. Closing Workspace leaves the session running."
        }
    }

    private var displayDirectory: String {
        let source = session.phase == .idle ? workingDirectory : session.workingDirectory
        return (source as NSString).abbreviatingWithTildeInPath
    }
}

struct WorkspaceTerminalPanel: View {
    @Bindable var appState: AppState
    let workingDirectory: String?

    var body: some View {
        EmbeddedTerminalTab(
            session: appState.embeddedTerminal,
            providerName: appState.config.general.provider.displayName,
            workingDirectory: resolvedWorkingDirectory,
            hasActiveSession: appState.hasActiveSession,
            onStart: {
                appState.newSession(workingDirectory: workingDirectory)
            },
            onEnd: {
                appState.endSession()
            },
            onOpenExternal: {
                appState.newSession(
                    workingDirectory: workingDirectory,
                    destination: .externalTerminal
                )
            }
        )
    }

    private var resolvedWorkingDirectory: String {
        let override = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = override.isEmpty ? appState.config.general.working_directory : override
        return WorkspaceFolder.url(from: configured).path
    }
}
