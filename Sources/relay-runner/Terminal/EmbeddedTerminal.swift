import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI

protocol EmbeddedTerminalProcess: AnyObject {
    var view: NSView { get }
    var isRunning: Bool { get }
    var hasFocus: Bool { get }
    var childPID: Int? { get }
    var onExit: ((Int32?) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
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
        case starting
        case running
        case external
        case ended
        case exited(Int32?)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .starting, .running, .external: return true
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
    @ObservationIgnored private var diagnostics: EmbeddedAgentDiagnostics?
    @ObservationIgnored private var providerKey: String?
    @ObservationIgnored private var supportCorrelationID: String?

    init(processFactory: @escaping ProcessFactory = { SwiftTermEmbeddedProcess() }) {
        self.processFactory = processFactory
    }

    var hostedView: NSView? { process?.view }
    var hasTerminalFocus: Bool { process?.hasFocus == true }
    var isEmbeddedProcessRunning: Bool {
        (phase == .starting || phase == .running) && process?.isRunning == true
    }
    var diagnosticEventPath: String? { diagnostics?.eventsURL.path }

    func setExitHandler(_ handler: @escaping (Int32?) -> Void) {
        exitHandler = handler
    }

    func beginPreparing(
        providerName: String,
        providerKey: String? = nil,
        workingDirectory: String,
        recordDiagnostics: Bool = false
    ) throws {
        guard !phase.isActive else { throw EmbeddedTerminalProcessError.alreadyRunning }
        self.providerName = providerName
        self.providerKey = providerKey
        self.workingDirectory = workingDirectory
        terminalTitle = ""
        diagnostics = recordDiagnostics
            ? EmbeddedAgentDiagnostics.start(
                provider: providerKey ?? providerName.lowercased(),
                workingDirectory: workingDirectory
            )
            : nil
        phase = .preparing
    }

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        guard phase == .preparing else { throw EmbeddedTerminalProcessError.alreadyRunning }
        supportCorrelationID = launch.diagnosticsCorrelationID
        RelayDiagnostics.shared.record(
            process: "provider",
            phase: "provider_readiness",
            outcome: "started",
            correlationID: launch.diagnosticsCorrelationID,
            provider: providerKey
        )

        let next = processFactory()
        next.onTitle = { [weak self, weak next] title in
            guard let self, let next, self.process === next else { return }
            self.terminalTitle = title
        }
        next.onReady = { [weak self, weak next] in
            let applyReady = { [weak self, weak next] in
                guard let self,
                      let next,
                      self.process === next,
                      self.phase == .starting else { return }
                self.diagnostics?.markInteractiveReady()
                self.phase = .running
                RelayDiagnostics.shared.record(
                    process: "provider",
                    phase: "provider_readiness",
                    outcome: "ready",
                    correlationID: self.supportCorrelationID ?? launch.diagnosticsCorrelationID,
                    provider: self.providerKey
                )
            }
            if Thread.isMainThread {
                applyReady()
            } else {
                DispatchQueue.main.async(execute: applyReady)
            }
        }
        next.onExit = { [weak self, weak next] rawStatus in
            guard let self, let next else { return }
            DispatchQueue.main.async { [weak self, weak next] in
                guard let self,
                      let next,
                      self.process === next else { return }
                let exitedBeforeReadiness = self.phase == .starting
                guard exitedBeforeReadiness || self.phase == .running else { return }
                let exitCode = Self.decodeWaitStatus(rawStatus)
                let providerSpawned = self.diagnostics.map {
                    $0.recordedOutcome(for: "provider_spawn") != nil
                } ?? true
                if exitedBeforeReadiness && !providerSpawned {
                    let bridgeOutcome = self.diagnostics?.recordedOutcome(
                        for: "bridge_socket_readiness"
                    )
                    self.diagnostics?.markLaunchFailed(rawStatus: rawStatus)
                    self.phase = .failed(Self.launchFailureMessage(
                        providerName: self.providerName,
                        rawStatus: rawStatus,
                        bridgeSocketOutcome: bridgeOutcome
                    ))
                    RelayDiagnostics.shared.record(
                        process: "provider",
                        phase: "provider_readiness",
                        outcome: "failed",
                        correlationID: self.supportCorrelationID ?? launch.diagnosticsCorrelationID,
                        provider: self.providerKey,
                        summary: "launcher exited before provider spawn",
                        attributes: ["exit_code": exitCode.map(String.init) ?? "unknown"]
                    )
                } else if exitedBeforeReadiness {
                    self.diagnostics?.markExited(
                        rawStatus: rawStatus,
                        beforeInteractiveReadiness: true
                    )
                    self.phase = .failed(Self.earlyExitMessage(
                        providerName: self.providerName,
                        rawStatus: rawStatus
                    ))
                    RelayDiagnostics.shared.record(
                        process: "provider",
                        phase: "provider_readiness",
                        outcome: "failed",
                        correlationID: self.supportCorrelationID ?? launch.diagnosticsCorrelationID,
                        provider: self.providerKey,
                        summary: "provider exited before interactive readiness",
                        attributes: ["exit_code": exitCode.map(String.init) ?? "unknown"]
                    )
                } else {
                    self.diagnostics?.markExited(
                        rawStatus: rawStatus,
                        beforeInteractiveReadiness: false
                    )
                    self.phase = .exited(exitCode)
                }
                self.exitHandler?(exitCode)
            }
        }

        process?.onExit = nil
        process?.onReady = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = next
        presentationRevision += 1
        diagnostics?.markLauncherPrepared(path: launch.launcherPath)
        phase = .starting

        do {
            try next.start(launch)
            guard next.isRunning else { throw EmbeddedTerminalProcessError.couldNotStart }
            diagnostics?.recordChildPID(next.childPID)
        } catch {
            next.onExit = nil
            next.onReady = nil
            next.onTitle = nil
            next.terminate()
            diagnostics?.markSetupFailed(message: error.localizedDescription)
            RelayDiagnostics.shared.record(
                process: "provider",
                phase: "provider_readiness",
                outcome: "failed",
                correlationID: supportCorrelationID ?? launch.diagnosticsCorrelationID,
                provider: providerKey,
                summary: error.localizedDescription,
                attributes: ["error_code": "process_start_failed"]
            )
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
        if case .failed = phase { return }
        diagnostics?.markSetupFailed(message: error.localizedDescription)
        phase = .failed(error.localizedDescription)
    }

    func end() {
        process?.onExit = nil
        process?.onReady = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            diagnostics?.markAppRequestedStop()
            process?.terminate()
        }
        phase = .ended
    }

    func shutdown() {
        process?.onExit = nil
        process?.onReady = nil
        process?.onTitle = nil
        if process?.isRunning == true {
            diagnostics?.markAppRequestedStop()
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

    static func terminationSignal(_ rawStatus: Int32?) -> Int32? {
        guard let rawStatus else { return nil }
        let signal = rawStatus & 0x7f
        return signal == 0 ? nil : signal
    }

    static func earlyExitMessage(providerName: String, rawStatus: Int32?) -> String {
        let outcome: String
        if let exitCode = decodeWaitStatus(rawStatus) {
            outcome = "exited with code \(exitCode)"
        } else if let signal = terminationSignal(rawStatus) {
            outcome = "terminated by signal \(signal)"
        } else {
            outcome = "exited"
        }
        return "\(providerName) \(outcome) during interactive provider readiness. Relay Runner stopped the orphaned voice bridge; start a new session to retry."
    }

    static func launchFailureMessage(
        providerName: String,
        rawStatus: Int32?,
        bridgeSocketOutcome: String?
    ) -> String {
        if bridgeSocketOutcome == "timeout" {
            return "The voice bridge socket timed out before \(providerName) started. Relay Runner cleaned up the partial session; start a new session to retry."
        }
        let outcome = decodeWaitStatus(rawStatus).map { " with code \($0)" } ?? ""
        return "The session launcher exited\(outcome) before \(providerName) started. Relay Runner cleaned up the partial session; start a new session to retry."
    }
}

final class RelayTerminalView: TerminalView {
    private(set) var isSendingTerminalResponse = false
    private(set) var isSendingNavigationShortcut = false
    private var navigationKeyMonitor: Any?
    private var rendererActivationAttempted = false

    deinit {
        uninstallNavigationKeyMonitor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            uninstallNavigationKeyMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installNavigationKeyMonitorIfNeeded()
        configureRendererFromEnvironmentIfNeeded()
    }

    @discardableResult
    func configureRendererFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        activateMetal: (() throws -> Void)? = nil
    ) -> Bool {
        guard environment["RELAY_RUNNER_TERMINAL_RENDERER"] == "metal" else { return false }
        do {
            if let activateMetal {
                try activateMetal()
            } else {
                try setUseMetal(true)
            }
            return isUsingMetalRenderer
        } catch {
            try? setUseMetal(false)
            NSLog("Relay Runner: SwiftTerm Metal activation failed; using CoreGraphics (%@)", String(describing: error))
            return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNavigationShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isSendingTerminalResponse = true
        defer { isSendingTerminalResponse = false }
        super.send(source: source, data: data)
    }

    @discardableResult
    func handleNavigationShortcut(_ event: NSEvent) -> Bool {
        guard let payload = Self.navigationShortcutPayload(for: event) else { return false }
        sendNavigationShortcut(payload)
        return true
    }

    func sendNavigationShortcut(_ payload: [UInt8]) {
        isSendingNavigationShortcut = true
        defer { isSendingNavigationShortcut = false }
        send(data: ArraySlice(payload))
    }

    static func navigationShortcutPayload(for event: NSEvent) -> [UInt8]? {
        switch event.keyCode {
        case 123:
            return navigationShortcutPayload(left: true, modifierFlags: event.modifierFlags)
        case 124:
            return navigationShortcutPayload(left: false, modifierFlags: event.modifierFlags)
        default:
            return nil
        }
    }

    private static func navigationShortcutPayload(
        left: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> [UInt8]? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let semanticFlags = flags.intersection([.command, .option, .control, .shift])
        switch semanticFlags {
        case .option:
            return left ? [27, 98] : [27, 102] // Esc-b / Esc-f.
        case .command:
            return left ? [1] : [5] // Ctrl-A / Ctrl-E.
        default:
            return nil
        }
    }

    private func installNavigationKeyMonitorIfNeeded() {
        guard window != nil, navigationKeyMonitor == nil else { return }
        navigationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.window?.firstResponder === self,
                  self.handleNavigationShortcut(event) else {
                return event
            }
            return nil
        }
    }

    private func configureRendererFromEnvironmentIfNeeded() {
        guard !rendererActivationAttempted else { return }
        rendererActivationAttempted = true
        _ = configureRendererFromEnvironment()
    }

    private func uninstallNavigationKeyMonitor() {
        guard let navigationKeyMonitor else { return }
        NSEvent.removeMonitor(navigationKeyMonitor)
        self.navigationKeyMonitor = nil
    }
}

/// SwiftTerm adapter with OSC 52 clipboard access denied. Explicit user copy
/// and paste still use TerminalView's normal AppKit commands.
struct RelayTerminalInputTracker: Equatable {
    enum Transition: Equatable {
        case none
        case draftChanged
        case submitted(pendingByteCount: Int)
        case cleared(pendingByteCount: Int)
    }

    private(set) var pendingByteCount = 0
    private var pendingInputUnitByteCounts: [Int] = []

    var hasUnsubmittedInput: Bool { pendingByteCount > 0 }

    @discardableResult
    mutating func record(data: ArraySlice<UInt8>) -> Transition {
        if let transition = recordKittyKeyEvent(data) { return transition }
        if isNavigationShortcut(data) { return .none }

        var transition: Transition = .none
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 3, 21:
                // Ctrl-C / Ctrl-U clears a partial prompt in both Codex and Claude.
                let previousCount = clearPendingInput()
                transition = .cleared(pendingByteCount: previousCount)
            case 10, 13:
                let previousCount = clearPendingInput()
                transition = .submitted(pendingByteCount: previousCount)
            case 8, 127:
                removeLastPendingInputUnit()
                if transition == .none { transition = .draftChanged }
            case 9, 32...126:
                appendPendingInputUnit(byteCount: 1)
                if transition == .none { transition = .draftChanged }
            case 0xc2...0xf4:
                let expectedLength: Int
                switch byte {
                case 0xc2...0xdf: expectedLength = 2
                case 0xe0...0xef: expectedLength = 3
                default: expectedLength = 4
                }
                let byteCount = min(expectedLength, bytes.count - index)
                appendPendingInputUnit(byteCount: byteCount)
                index += byteCount - 1
                if transition == .none { transition = .draftChanged }
            case 0x80...0xff:
                appendPendingInputUnit(byteCount: 1)
                if transition == .none { transition = .draftChanged }
            default:
                break
            }
            index += 1
        }
        return transition
    }

    private func isNavigationShortcut(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        return bytes == [27, 98] || bytes == [27, 102] || bytes == [1] || bytes == [5]
    }

    private mutating func recordKittyKeyEvent(_ data: ArraySlice<UInt8>) -> Transition? {
        guard data.count >= 4,
              data[data.startIndex] == 27,
              data[data.index(after: data.startIndex)] == 91,
              data[data.index(before: data.endIndex)] == 117 else {
            return nil
        }

        let bodyStart = data.index(data.startIndex, offsetBy: 2)
        let bodyEnd = data.index(before: data.endIndex)
        let fields = String(decoding: data[bodyStart..<bodyEnd], as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        guard let keyField = fields.first,
              let keyCode = Int(keyField.split(separator: ":", omittingEmptySubsequences: false)[0]) else {
            return nil
        }

        let modifierField = fields.count > 1 ? fields[1] : ""
        let modifierParts = modifierField.split(separator: ":", omittingEmptySubsequences: false)
        let modifierMask = max(0, (Int(modifierParts.first ?? "") ?? 1) - 1)
        let eventType = modifierParts.count > 1 ? Int(modifierParts[1]) ?? 1 : 1
        if eventType == 3 { return Transition.none }

        let controlIsPressed = modifierMask & 4 != 0
        if controlIsPressed {
            if keyCode == 99 || keyCode == 117 {
                let previousCount = clearPendingInput()
                return .cleared(pendingByteCount: previousCount)
            }
            return Transition.none
        }

        switch keyCode {
        case 3, 21:
            let previousCount = clearPendingInput()
            return .cleared(pendingByteCount: previousCount)
        case 10, 13:
            let previousCount = clearPendingInput()
            return .submitted(pendingByteCount: previousCount)
        case 8, 127:
            removeLastPendingInputUnit()
            return .draftChanged
        case 9:
            appendPendingInputUnit(byteCount: 1)
            return .draftChanged
        case 32...0x10ffff where !(0xe000...0xf8ff).contains(keyCode):
            if let scalar = UnicodeScalar(keyCode) {
                appendPendingInputUnit(byteCount: String(scalar).utf8.count)
                return .draftChanged
            }
            return Transition.none
        default:
            return Transition.none
        }
    }

    private mutating func appendPendingInputUnit(byteCount: Int) {
        let count = max(1, byteCount)
        pendingInputUnitByteCounts.append(count)
        pendingByteCount += count
    }

    private mutating func removeLastPendingInputUnit() {
        guard let removed = pendingInputUnitByteCounts.popLast() else {
            pendingByteCount = 0
            return
        }
        pendingByteCount = max(0, pendingByteCount - removed)
    }

    @discardableResult
    private mutating func clearPendingInput() -> Int {
        let previousCount = pendingByteCount
        pendingByteCount = 0
        pendingInputUnitByteCounts.removeAll(keepingCapacity: true)
        return previousCount
    }
}

/// RR-122/RR-163/RR-211/RR-218/RR-222/RR-238 each guarded one edge of
/// app-owned delivery, but their independent input counter, active-turn check,
/// submit timeout, and recovery writes did not share command ownership. This
/// state machine is the sole owner from ready-file observation through an exact
/// provider acknowledgement or a process-terminal failure.
final class RelayVoiceCommandDelivery {
    struct Paths: Equatable {
        var command = "/tmp/voice_cmd_ready"
        var metadata = "/tmp/voice_cmd_ready.meta"
        var claimed = "/tmp/voice_cmd_claimed.json"
        var consumerAcknowledgement = "/tmp/voice_cmd_manual_ack.json"
        var commandState = "/tmp/voice_command_state.json"
        var providerTurns = "/tmp/voice_provider_turns.json"
        var deliveryEvents = "/tmp/relay_terminal_delivery_events.jsonl"
        var actionJournal = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("relay-runner/command-actions/events.jsonl")
            .path
        var voiceInput = "/tmp/voice_in.fifo"
        var heartbeat = "/tmp/voice_bridge_heartbeat"
    }

    struct ClaimedCommand: Equatable {
        let text: String
        let metadata: Data?
    }

    private struct RelayCommandKey: Equatable {
        let seq: Int
        let id: String
        let provider: String?
        let intentID: String?

        static func == (lhs: RelayCommandKey, rhs: RelayCommandKey) -> Bool {
            guard lhs.seq == rhs.seq && lhs.id == rhs.id else { return false }
            if lhs.intentID != nil || rhs.intentID != nil {
                return lhs.intentID == rhs.intentID
            }
            return true
        }
    }

    private struct PendingSubmission: Equatable {
        let key: RelayCommandKey
        let events: [[UInt8]]
        let submittedAt: Date
    }

    private struct BufferedManualInput: Equatable {
        let key: RelayCommandKey
        var events: [[UInt8]] = []
        var voiceBoundaryReached = false

        var pendingByteCount: Int {
            events.reduce(0) { $0 + $1.count }
        }
    }

    private enum SafeBoundaryReason: String, Equatable {
        case manualSubmission = "manual_submission"
        case manualDraftCleared = "manual_draft_cleared"
        case providerTurn = "provider_turn"
        case providerPreemption = "provider_preemption"
    }

    private struct ManualBoundary: Equatable {
        let startedAt: Date
        let reason: SafeBoundaryReason
    }

    private struct Deferral: Equatable {
        let key: RelayCommandKey
        let queuedAt: Date
        let barrierStartedAt: Date?
        let reason: SafeBoundaryReason?
        var lastDiagnosticAt: Date
    }

    private enum DeliveryState: Equatable {
        case idle
        case queued(key: RelayCommandKey, since: Date)
        case blockedByDraft(Deferral)
        case waitingForSafeBoundary(Deferral)
        case promptWritten(PendingSubmission)
        case awaitingAcknowledgement(PendingSubmission)
        case recovering(PendingSubmission, since: Date)
        case acknowledged(RelayCommandKey)
        case superseded(RelayCommandKey)
        case terminalFailure(RelayCommandKey)

        var isTerminal: Bool {
            switch self {
            case .acknowledged, .superseded, .terminalFailure:
                return true
            default:
                return false
            }
        }
    }

    typealias Send = (ArraySlice<UInt8>) -> Void
    typealias TransportSend = (ArraySlice<UInt8>, @escaping () -> Void) -> Void
    typealias Schedule = (TimeInterval, DispatchQueue, @escaping () -> Void) -> Void

    private let paths: Paths
    private let send: Send
    private let transportSend: TransportSend
    private let schedule: Schedule
    private let submitDelay: TimeInterval
    private let acknowledgementTimeout: TimeInterval
    private let clearedDraftSafetyDelay: TimeInterval
    private let deferralDiagnosticInterval: TimeInterval
    private let isRunning: () -> Bool
    private let fileManager: FileManager
    private let now: () -> Date
    private let providerSessionID: String?
    private let queue = DispatchQueue(label: "relay-runner.voice-command-delivery")
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueIdentity = UUID()
    private var timer: DispatchSourceTimer?
    private var inputTracker = RelayTerminalInputTracker()
    private var deliveryState: DeliveryState = .idle
    private var manualBoundary: ManualBoundary?
    private var bufferedManualInput: BufferedManualInput?
    private var deliveryOrder = 0

    init(
        paths: Paths = Paths(),
        send: @escaping Send,
        transportSend: TransportSend? = nil,
        submitDelay: TimeInterval = 0.12,
        acknowledgementTimeout: TimeInterval = 2.0,
        clearedDraftSafetyDelay: TimeInterval = 0.25,
        deferralDiagnosticInterval: TimeInterval = 5.0,
        schedule: @escaping Schedule = { delay, queue, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        },
        isRunning: @escaping () -> Bool,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        providerSessionID: String? = nil
    ) {
        self.paths = paths
        self.send = send
        self.transportSend = transportSend ?? { data, confirmation in
            send(data)
            confirmation()
        }
        self.submitDelay = submitDelay
        self.acknowledgementTimeout = acknowledgementTimeout
        self.clearedDraftSafetyDelay = max(0, clearedDraftSafetyDelay)
        self.deferralDiagnosticInterval = max(0.25, deferralDiagnosticInterval)
        self.schedule = schedule
        self.isRunning = isRunning
        self.fileManager = fileManager
        self.now = now
        self.providerSessionID = providerSessionID
        queue.setSpecific(key: queueKey, value: queueIdentity)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                self?.claimAndSendIfPossible()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func providerProcessTerminated(releaseReason: String = "provider_process_terminated") {
        performOnDeliveryQueue {
            timer?.cancel()
            timer = nil
            if !completePendingSubmissionIfAcknowledged(), let pending = openSubmission {
                finalizePendingSubmission(pending, event: "provider_process_terminated")
            }
            releaseActiveProviderTurns(reason: releaseReason)
        }
    }

    @discardableResult
    func recordUserInput(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return true }
        let recordedAt = now()
        return queue.sync {
            if let key = manualInputBufferKey {
                bufferManualInput(bytes, key: key)
                return false
            }
            let transition = self.inputTracker.record(data: ArraySlice(bytes))
            self.recordUserInputTransition(transition, recordedAt: recordedAt)
            return true
        }
    }

    private func recordUserInputTransition(
        _ transition: RelayTerminalInputTracker.Transition,
        recordedAt: Date
    ) {
        guard !hasSubmittedVoicePrompt else { return }
        switch transition {
        case .submitted(let pendingByteCount) where pendingByteCount > 0:
            let boundary = ManualBoundary(
                startedAt: recordedAt,
                reason: .manualSubmission
            )
            manualBoundary = boundary
            if let key = pendingCommandKey() {
                recordDeliveryEvent(
                    "manual_submit_barrier_started",
                    key: key,
                    fields: ["pending_byte_count": pendingByteCount]
                )
                deferForSafeBoundary(key: key, boundary: boundary)
            }
        case .cleared(let pendingByteCount) where pendingByteCount > 0:
            let boundary = ManualBoundary(
                startedAt: recordedAt,
                reason: .manualDraftCleared
            )
            manualBoundary = boundary
            if let key = pendingCommandKey() {
                recordDeliveryEvent(
                    "manual_clear_barrier_started",
                    key: key,
                    fields: ["pending_byte_count": pendingByteCount]
                )
                deferForSafeBoundary(key: key, boundary: boundary)
            }
        default:
            break
        }
    }

    @discardableResult
    func claimAndSendIfPossible() -> Bool {
        touchHeartbeat()
        let completedSubmission = completePendingSubmissionIfAcknowledged()
        if let pending = openSubmission, !isRunning() {
            failPendingSubmission(pending, event: "provider_process_terminated")
            return true
        }
        let replayedManualInput = replayBufferedManualInputIfPossible()
        if bufferedManualInput != nil {
            return completedSubmission || replayedManualInput
        }
        if completedSubmission || replayedManualInput {
            return true
        }
        guard isRunning(), openSubmission == nil else { return false }
        if deliveryState.isTerminal {
            deliveryState = .idle
        }

        guard let key = pendingCommandKey() else { return false }
        observeQueuedCommand(key)
        if inputTracker.hasUnsubmittedInput {
            deferForTerminalDraft(key: key)
            touchPendingCommand()
            return false
        }
        if let boundary = manualBoundary {
            guard safeBoundaryReached(boundary) else {
                deferForSafeBoundary(key: key, boundary: boundary)
                touchPendingCommand()
                return false
            }
            recordDeliveryEvent(
                "safe_boundary_verified",
                key: key,
                fields: [
                    "barrier_elapsed_ms": elapsedMilliseconds(since: boundary.startedAt),
                    "deferral_reason": boundary.reason.rawValue,
                ]
            )
            manualBoundary = nil
            deliveryState = .queued(key: key, since: queuedAt(for: key))
        }

        let pendingText = peekPendingCommandText()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if providerTurnActive(), pendingText != "__INTERRUPT__" {
            if pendingCommandRequestsProviderPreemption() {
                if !isWaitingForProviderPreemption(key) {
                    send(ArraySlice([3]))
                    recordDeliveryEvent("provider_preemption_requested", key: key)
                }
                deferForProviderTurn(key: key, reason: .providerPreemption)
            } else {
                deferForProviderTurn(key: key, reason: .providerTurn)
            }
            touchPendingCommand()
            return false
        }
        if case .waitingForSafeBoundary(let deferral) = deliveryState,
           deferral.key == key,
           deferral.reason == .providerTurn || deferral.reason == .providerPreemption {
            var fields: [String: Any] = [
                "deferral_reason": deferral.reason?.rawValue ?? "provider_turn"
            ]
            fields.merge(providerTurnDiagnosticFields(activeOnly: false)) { current, _ in current }
            recordDeliveryEvent(
                "safe_boundary_verified",
                key: key,
                fields: fields
            )
            deliveryState = .queued(key: key, since: deferral.queuedAt)
        }

        guard let command = claimNextCommand() else { return false }
        guard Self.relayCommandKey(from: command.metadata) == key else {
            deliveryState = .terminalFailure(key)
            recordDeliveryEvent("terminal_failure", key: key, fields: ["deferral_reason": "metadata_mismatch"])
            return true
        }
        guard let events = Self.providerInputEvents(for: command.text) else {
            writeClaimedMetadata(command.metadata)
            writeConsumerAcknowledgement(command.metadata)
            deliveryState = .superseded(key)
            recordDeliveryEvent("superseded", key: key, fields: ["deferral_reason": "control"])
            recordDeliveryEvent("claim_published", key: key)
            return true
        }
        guard let first = events.first else { return true }
        if !isCommandCurrent(key) {
            deliveryState = .superseded(key)
            recordDeliveryEvent("stale_command_dropped", key: key)
            return true
        }
        recordDeliveryEvent("claimed", key: key)
        if command.text.trimmingCharacters(in: .whitespacesAndNewlines) == "__INTERRUPT__" {
            if providerTurnActive() {
                send(ArraySlice(first))
            }
            writeClaimedMetadata(command.metadata)
            writeConsumerAcknowledgement(command.metadata)
            recordDeliveryEvent("claim_published", key: key)
            deliveryState = .acknowledged(key)
            return true
        }
        guard events.count > 1 else {
            send(ArraySlice(first))
            recordDeliveryEvent("prompt_write", key: key)
            writeClaimedMetadata(command.metadata)
            // One-event controls do not produce a provider hook turn, so the
            // terminal consumer must acknowledge them to release the inbox.
            writeConsumerAcknowledgement(command.metadata)
            recordDeliveryEvent("claim_published", key: key)
            deliveryState = .acknowledged(key)
            return true
        }
        let pending = PendingSubmission(
            key: key,
            events: Array(events.dropFirst()),
            submittedAt: now()
        )
        deliveryState = .promptWritten(pending)
        send(ArraySlice(first))
        recordDeliveryEvent("prompt_write", key: key)
        schedule(submitDelay, queue) { [weak self] in
            guard let self else { return }
            guard case .promptWritten(let current) = self.deliveryState,
                  current.key == key else { return }
            guard self.isRunning() else {
                self.failPendingSubmission(current, event: "provider_process_terminated")
                return
            }
            self.touchHeartbeat()
            if !self.isCommandCurrent(key) {
                self.send(ArraySlice([21]))
                self.deliveryState = .superseded(key)
                self.recordDeliveryEvent("stale_prompt_cleared", key: key)
                _ = self.replayBufferedManualInputIfPossible()
                return
            }
            self.writeClaimedMetadata(command.metadata)
            self.recordDeliveryEvent("claim_published", key: key)
            self.sendPendingSubmissionEvents(current)
        }
        return true
    }

    private func sendPendingSubmissionEvents(_ pending: PendingSubmission, index: Int = 0) {
        guard case .promptWritten(let current) = deliveryState,
              current.key == pending.key,
              current.events.indices.contains(index) else { return }
        let event = current.events[index]
        recordDeliveryEvent(
            "submit_attempt",
            key: current.key,
            fields: ["attempt": 1, "transport_event_index": index]
        )
        transportSend(ArraySlice(event)) { [weak self] in
            guard let self else { return }
            self.performOnDeliveryQueue {
                guard case .promptWritten(let confirmed) = self.deliveryState,
                      confirmed.key == pending.key,
                      confirmed.events.indices.contains(index) else { return }
                self.recordDeliveryEvent(
                    "submit_transport_confirmed",
                    key: confirmed.key,
                    fields: ["attempt": 1, "transport_event_index": index]
                )
                let nextIndex = index + 1
                if confirmed.events.indices.contains(nextIndex) {
                    self.sendPendingSubmissionEvents(confirmed, index: nextIndex)
                    return
                }
                self.deliveryState = .awaitingAcknowledgement(confirmed)
                self.restoreBufferedManualDraft()
                self.schedule(self.acknowledgementTimeout, self.queue) { [weak self] in
                    self?.handleAcknowledgementTimeout(for: confirmed.key)
                }
            }
        }
    }

    private func performOnDeliveryQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == queueIdentity {
            work()
        } else {
            queue.sync {
                work()
            }
        }
    }

    private var openSubmission: PendingSubmission? {
        switch deliveryState {
        case .promptWritten(let pending),
             .awaitingAcknowledgement(let pending),
             .recovering(let pending, _):
            return pending
        default:
            return nil
        }
    }

    private var hasSubmittedVoicePrompt: Bool {
        openSubmission != nil
    }

    private var manualInputBufferKey: RelayCommandKey? {
        if let bufferedManualInput {
            return bufferedManualInput.key
        }
        if case .promptWritten(let pending) = deliveryState {
            return pending.key
        }
        return nil
    }

    private func bufferManualInput(_ bytes: [UInt8], key: RelayCommandKey) {
        var buffered = bufferedManualInput ?? BufferedManualInput(key: key)
        buffered.events.append(contentsOf: Self.manualInputSegments(bytes))
        bufferedManualInput = buffered
        recordDeliveryEvent(
            "manual_input_quarantined",
            key: buffered.key,
            fields: [
                "deferral_reason": "voice_submit_delay",
                "pending_byte_count": buffered.pendingByteCount,
            ]
        )
    }

    private static func manualInputSegments(_ bytes: [UInt8]) -> [[UInt8]] {
        guard bytes.contains(where: { $0 == 10 || $0 == 13 }) else {
            return [bytes]
        }
        var segments: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 10 || byte == 13 {
                if !current.isEmpty {
                    segments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                segments.append([byte])
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private func eventSubmitsManualInput(_ event: [UInt8]) -> Bool {
        var preview = inputTracker
        if case .submitted = preview.record(data: ArraySlice(event)) {
            return true
        }
        return false
    }

    private func restoreBufferedManualDraft() {
        guard var buffered = bufferedManualInput else { return }
        var replayedByteCount = 0
        var replayedEventCount = 0
        while let event = buffered.events.first,
              !eventSubmitsManualInput(event) {
            buffered.events.removeFirst()
            let transition = inputTracker.record(data: ArraySlice(event))
            recordUserInputTransition(transition, recordedAt: now())
            send(ArraySlice(event))
            replayedByteCount += event.count
            replayedEventCount += 1
        }
        bufferedManualInput = buffered.events.isEmpty ? nil : buffered
        guard replayedEventCount > 0 else { return }
        recordDeliveryEvent(
            "manual_draft_restored",
            key: buffered.key,
            fields: [
                "input_event_count": replayedEventCount,
                "pending_byte_count": bufferedManualInput?.pendingByteCount ?? 0,
                "replayed_byte_count": replayedByteCount,
            ]
        )
    }

    @discardableResult
    private func replayBufferedManualInputIfPossible() -> Bool {
        guard isRunning(), var buffered = bufferedManualInput else { return false }
        if !buffered.voiceBoundaryReached {
            let voiceBoundaryReached: Bool
            switch deliveryState {
            case .acknowledged(let key), .superseded(let key):
                voiceBoundaryReached = key == buffered.key && !providerTurnActive()
            default:
                voiceBoundaryReached = false
            }
            guard voiceBoundaryReached else { return false }
            buffered.voiceBoundaryReached = true
            bufferedManualInput = buffered
        }
        if let boundary = manualBoundary {
            guard safeBoundaryReached(boundary) else { return false }
            manualBoundary = nil
        }

        restoreBufferedManualDraft()
        guard var pending = bufferedManualInput,
              let submitEvent = pending.events.first,
              eventSubmitsManualInput(submitEvent) else {
            return true
        }
        pending.events.removeFirst()
        bufferedManualInput = pending.events.isEmpty ? nil : pending
        let transition = inputTracker.record(data: ArraySlice(submitEvent))
        recordUserInputTransition(transition, recordedAt: now())
        send(ArraySlice(submitEvent))
        recordDeliveryEvent(
            "manual_submit_replayed",
            key: pending.key,
            fields: [
                "pending_byte_count": bufferedManualInput?.pendingByteCount ?? 0,
                "replayed_byte_count": submitEvent.count,
            ]
        )
        restoreBufferedManualDraft()
        return true
    }

    private func observeQueuedCommand(_ key: RelayCommandKey) {
        switch deliveryState {
        case .queued(let existing, _) where existing == key:
            return
        case .blockedByDraft(let deferral) where deferral.key == key:
            return
        case .waitingForSafeBoundary(let deferral) where deferral.key == key:
            return
        default:
            let observedAt = pendingCommandModificationDate() ?? now()
            deliveryState = .queued(key: key, since: observedAt)
            recordDeliveryEvent("queued", key: key)
        }
    }

    private func queuedAt(for key: RelayCommandKey) -> Date {
        switch deliveryState {
        case .queued(let existing, let since) where existing == key:
            return since
        case .blockedByDraft(let deferral) where deferral.key == key:
            return deferral.queuedAt
        case .waitingForSafeBoundary(let deferral) where deferral.key == key:
            return deferral.queuedAt
        default:
            return pendingCommandModificationDate() ?? now()
        }
    }

    private func pendingCommandModificationDate() -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: paths.command)
        return attributes?[.modificationDate] as? Date
    }

    private func deferForTerminalDraft(key: RelayCommandKey) {
        var deferral: Deferral
        if case .blockedByDraft(let existing) = deliveryState, existing.key == key {
            deferral = existing
        } else {
            deferral = Deferral(
                key: key,
                queuedAt: queuedAt(for: key),
                barrierStartedAt: nil,
                reason: nil,
                lastDiagnosticAt: .distantPast
            )
        }
        let currentTime = now()
        if currentTime.timeIntervalSince(deferral.lastDiagnosticAt) >= deferralDiagnosticInterval {
            recordDeliveryEvent(
                "deferred_terminal_draft",
                key: key,
                fields: [
                    "barrier_elapsed_ms": deferral.barrierStartedAt.map {
                        elapsedMilliseconds(since: $0)
                    } ?? 0,
                    "elapsed_ms": elapsedMilliseconds(since: deferral.queuedAt),
                    "pending_byte_count": inputTracker.pendingByteCount,
                    "deferral_reason": "terminal_draft",
                ]
            )
            deferral.lastDiagnosticAt = currentTime
        }
        deliveryState = .blockedByDraft(deferral)
    }

    private func deferForSafeBoundary(key: RelayCommandKey, boundary: ManualBoundary) {
        deferForSafeBoundary(
            key: key,
            barrierStartedAt: boundary.startedAt,
            reason: boundary.reason
        )
    }

    private func deferForProviderTurn(key: RelayCommandKey, reason: SafeBoundaryReason) {
        deferForSafeBoundary(
            key: key,
            barrierStartedAt: now(),
            reason: reason
        )
    }

    private func deferForSafeBoundary(
        key: RelayCommandKey,
        barrierStartedAt: Date,
        reason: SafeBoundaryReason
    ) {
        var deferral: Deferral
        if case .waitingForSafeBoundary(let existing) = deliveryState,
           existing.key == key,
           existing.reason == reason {
            deferral = existing
        } else {
            deferral = Deferral(
                key: key,
                queuedAt: queuedAt(for: key),
                barrierStartedAt: barrierStartedAt,
                reason: reason,
                lastDiagnosticAt: .distantPast
            )
        }
        let currentTime = now()
        if currentTime.timeIntervalSince(deferral.lastDiagnosticAt) >= deferralDiagnosticInterval {
            var fields: [String: Any] = [
                "elapsed_ms": elapsedMilliseconds(since: deferral.queuedAt),
                "pending_byte_count": inputTracker.pendingByteCount,
                "deferral_reason": reason.rawValue,
            ]
            fields.merge(providerTurnDiagnosticFields(activeOnly: true)) { current, _ in current }
            recordDeliveryEvent(
                "safe_boundary_wait",
                key: key,
                fields: fields
            )
            deferral.lastDiagnosticAt = currentTime
        }
        deliveryState = .waitingForSafeBoundary(deferral)
    }

    private func isWaitingForProviderPreemption(_ key: RelayCommandKey) -> Bool {
        guard case .waitingForSafeBoundary(let deferral) = deliveryState else { return false }
        return deferral.key == key && deferral.reason == .providerPreemption
    }

    private func safeBoundaryReached(_ boundary: ManualBoundary) -> Bool {
        switch boundary.reason {
        case .manualDraftCleared:
            return now().timeIntervalSince(boundary.startedAt) >= clearedDraftSafetyDelay
                && !providerTurnActive()
        case .manualSubmission:
            let records = providerTurnRecords().filter { record in
                let createdAt = (record["created_at"] as? NSNumber)?.doubleValue
                    ?? (record["updated_at"] as? NSNumber)?.doubleValue
                    ?? 0
                return createdAt >= boundary.startedAt.timeIntervalSince1970 - 0.25
                    && (record["origin"] as? String) == "manual"
            }
            guard !records.isEmpty else { return false }
            return !records.contains {
                ($0["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
            }
        case .providerTurn, .providerPreemption:
            return !providerTurnActive()
        }
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(now().timeIntervalSince(date) * 1_000))
    }

    func claimNextCommand() -> ClaimedCommand? {
        let commandURL = URL(fileURLWithPath: paths.command)
        let metadataURL = URL(fileURLWithPath: paths.metadata)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_cmd_claim.\(UUID().uuidString)")
        let tempMetadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_cmd_claim.\(UUID().uuidString).meta")

        do {
            try fileManager.moveItem(at: commandURL, to: tempURL)
        } catch {
            return nil
        }

        var metadataData: Data?
        if fileManager.fileExists(atPath: metadataURL.path),
           (try? fileManager.moveItem(at: metadataURL, to: tempMetadataURL)) != nil {
            metadataData = try? Data(contentsOf: tempMetadataURL)
        }

        let rawText = (try? String(contentsOf: tempURL, encoding: .utf8)) ?? ""
        try? fileManager.removeItem(at: tempURL)
        try? fileManager.removeItem(at: tempMetadataURL)

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ClaimedCommand(text: text, metadata: metadataData)
    }

    static func providerInputEvents(for text: String) -> [[UInt8]]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "__INTERRUPT__" {
            return [[3]]
        }
        if trimmed.hasPrefix("__") {
            return nil
        }
        return [Array(trimmed.utf8), [13]]
    }

    private func writeClaimedMetadata(_ metadata: Data?) {
        guard let metadata else { return }
        let claimedURL = URL(fileURLWithPath: paths.claimed)
        try? metadata.write(to: claimedURL, options: .atomic)
    }

    private func writeConsumerAcknowledgement(_ metadata: Data?) {
        guard let metadata else { return }
        let acknowledgementURL = URL(fileURLWithPath: paths.consumerAcknowledgement)
        try? metadata.write(to: acknowledgementURL, options: .atomic)
    }

    private func isCommandCurrent(_ key: RelayCommandKey) -> Bool {
        let stateURL = URL(fileURLWithPath: paths.commandState)
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let stateKey = Self.relayCommandKey(from: object), stateKey == key {
            return true
        }
        let deliverable = object["deliverable_commands"] as? [[String: Any]] ?? []
        return deliverable.contains { Self.relayCommandKey(from: $0) == key }
    }

    private func pendingCommandRequestsProviderPreemption() -> Bool {
        let metadataURL = URL(fileURLWithPath: paths.metadata)
        return metadataRequestsProviderPreemption(try? Data(contentsOf: metadataURL))
    }

    private func metadataRequestsProviderPreemption(_ data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if object["preempt_provider"] as? Bool == true {
            return true
        }
        let disposition = object["work_disposition"] as? [String: Any]
        let scope = (object["cancellation_scope"] as? String)
            ?? (disposition?["cancellation_scope"] as? String)
        if scope == "all_work" {
            return true
        }
        let targetIDs = Set(object["provider_preempt_intent_ids"] as? [String] ?? [])
        guard !targetIDs.isEmpty else { return false }
        let turnsURL = URL(fileURLWithPath: paths.providerTurns)
        guard let turnsData = try? Data(contentsOf: turnsURL),
              let turns = try? JSONSerialization.jsonObject(with: turnsData) as? [String: Any],
              let records = turns["records"] as? [[String: Any]] else {
            return false
        }
        let active = records.filter { ($0["state"] as? String) == "active" }
        let current = active.max { lhs, rhs in
            let lhsUpdated = (lhs["updated_at"] as? NSNumber)?.doubleValue ?? 0
            let rhsUpdated = (rhs["updated_at"] as? NSNumber)?.doubleValue ?? 0
            return lhsUpdated < rhsUpdated
        }
        return targetIDs.contains(current?["intent_id"] as? String ?? "")
    }

    private func providerTurnActive() -> Bool {
        providerTurnRecords().contains { record in
            (record["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        }
    }

    private func providerTurnRecords() -> [[String: Any]] {
        let turnsURL = URL(fileURLWithPath: paths.providerTurns)
        guard let data = try? Data(contentsOf: turnsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let records = object["records"] as? [[String: Any]] ?? []
        guard let providerSessionID, !providerSessionID.isEmpty else { return records }
        return records.filter {
            ($0["provider_session_id"] as? String) == providerSessionID
        }
    }

    private func providerTurnDiagnosticFields(activeOnly: Bool) -> [String: Any] {
        let records = providerTurnRecords().filter {
            !activeOnly || ($0["state"] as? String) == "active"
        }
        guard let record = records.max(by: { lhs, rhs in
            let lhsUpdated = (lhs["updated_at"] as? NSNumber)?.doubleValue
                ?? (lhs["created_at"] as? NSNumber)?.doubleValue
                ?? 0
            let rhsUpdated = (rhs["updated_at"] as? NSNumber)?.doubleValue
                ?? (rhs["created_at"] as? NSNumber)?.doubleValue
                ?? 0
            return lhsUpdated < rhsUpdated
        }) else { return [:] }
        var fields: [String: Any] = [:]
        let mappings = [
            ("provider", "provider_turn_provider"),
            ("origin", "provider_turn_origin"),
            ("provider_session_id", "provider_session_id"),
            ("session_id", "provider_native_session_id"),
            ("turn_id", "provider_native_turn_id"),
            ("state", "provider_turn_record_state"),
            ("release_reason", "provider_turn_release_reason"),
        ]
        for (source, destination) in mappings {
            if let value = record[source] as? String, !value.isEmpty {
                fields[destination] = value
            }
        }
        let createdAt = (record["created_at"] as? NSNumber)?.doubleValue
            ?? (record["updated_at"] as? NSNumber)?.doubleValue
        if let createdAt {
            fields["provider_turn_age_ms"] = max(
                0,
                Int((now().timeIntervalSince1970 - createdAt) * 1_000)
            )
        }
        return fields
    }

    private func releaseActiveProviderTurns(reason: String) {
        let turnsURL = URL(fileURLWithPath: paths.providerTurns)
        guard let data = try? Data(contentsOf: turnsURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var records = object["records"] as? [[String: Any]] else { return }
        var changed = false
        for index in records.indices where (records[index]["state"] as? String) == "active" {
            if let providerSessionID,
               (records[index]["provider_session_id"] as? String) != providerSessionID {
                continue
            }
            records[index]["state"] = "terminated"
            records[index]["release_reason"] = reason
            records[index]["updated_at"] = now().timeIntervalSince1970
            changed = true
        }
        guard changed else { return }
        object["records"] = records
        object["updated_at"] = now().timeIntervalSince1970
        guard let updated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        try? updated.write(to: turnsURL, options: .atomic)
    }

    private func providerTurnState(for key: RelayCommandKey) -> String? {
        for record in providerTurnRecords().reversed() where Self.relayCommandKey(from: record) == key {
            let state = (record["state"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return state?.isEmpty == false ? state : nil
        }
        return nil
    }

    @discardableResult
    private func completePendingSubmissionIfAcknowledged() -> Bool {
        guard let pending = openSubmission,
              let state = providerTurnState(for: pending.key),
              state != "stale" else {
            return false
        }
        if case .recovering = deliveryState {
            recordDeliveryEvent(
                "late_ack_reconciled",
                key: pending.key,
                fields: ["provider_turn_state": state]
            )
        }
        recordDeliveryEvent(
            "provider_acknowledged",
            key: pending.key,
            fields: ["attempt": 1, "provider_turn_state": state]
        )
        recordDeliveryEvent("delivery_acknowledged", key: pending.key)
        deliveryState = .acknowledged(pending.key)
        return true
    }

    private func handleAcknowledgementTimeout(for key: RelayCommandKey) {
        touchHeartbeat()
        guard case .awaitingAcknowledgement(let pending) = deliveryState,
              pending.key == key else {
            return
        }
        if completePendingSubmissionIfAcknowledged() {
            return
        }
        guard isRunning() else {
            failPendingSubmission(pending, event: "provider_process_terminated")
            return
        }
        recordDeliveryEvent(
            "acknowledgement_timeout",
            key: key,
            fields: [
                "attempt": 1,
                "elapsed_ms": elapsedMilliseconds(since: pending.submittedAt),
            ]
        )
        deliveryState = .recovering(pending, since: now())
        recordDeliveryEvent("recovery_started", key: key, fields: ["attempt": 1])
        scheduleRecoveryPoll(for: key)
    }

    private func scheduleRecoveryPoll(for key: RelayCommandKey) {
        schedule(min(max(acknowledgementTimeout, 0.1), 0.5), queue) { [weak self] in
            guard let self,
                  case .recovering(let pending, _) = self.deliveryState,
                  pending.key == key else { return }
            self.touchHeartbeat()
            if self.completePendingSubmissionIfAcknowledged() {
                return
            }
            guard self.isRunning() else {
                self.failPendingSubmission(pending, event: "provider_process_terminated")
                return
            }
            self.scheduleRecoveryPoll(for: key)
        }
    }

    private func failPendingSubmission(_ pending: PendingSubmission, event: String) {
        guard !isRunning() else {
            deliveryState = .recovering(pending, since: now())
            return
        }
        finalizePendingSubmission(pending, event: event)
    }

    private func finalizePendingSubmission(_ pending: PendingSubmission, event: String) {
        guard openSubmission?.key == pending.key else { return }
        recordDeliveryEvent(event, key: pending.key, fields: ["attempt": 1])
        let published = publishDeliveryFailure(for: pending.key)
        deliveryState = .terminalFailure(pending.key)
        recordDeliveryEvent(
            published ? "delivery_failure_published" : "delivery_failure_publish_failed",
            key: pending.key
        )
    }

    @discardableResult
    private func publishDeliveryFailure(for key: RelayCommandKey) -> Bool {
        var payload: [String: Any] = [
            "text": "The provider session ended before it acknowledged the voice command. The original command can no longer execute; please start a session and try again.",
            "relay_command_seq": key.seq,
            "relay_command_id": key.id,
        ]
        if let provider = key.provider {
            payload["provider"] = provider
        }
        if let intentID = key.intentID {
            payload["intent_id"] = intentID
        }
        return writeOrchestratorReply(payload)
    }

    @discardableResult
    private func writeOrchestratorReply(_ payload: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return writeBridgeControlLine("__ORCHESTRATOR_REPLY__:\(json)")
    }

    @discardableResult
    private func writeBridgeControlLine(_ line: String) -> Bool {
        guard fileManager.fileExists(atPath: paths.voiceInput) else { return false }
        let fd = Darwin.open(paths.voiceInput, O_WRONLY | O_NONBLOCK | O_APPEND)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let bytes = Array((line + "\n").utf8)
        let written = bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return Darwin.write(fd, baseAddress, buffer.count)
        }
        return written == bytes.count
    }

    private func peekPendingCommandText() -> String? {
        let commandURL = URL(fileURLWithPath: paths.command)
        return try? String(contentsOf: commandURL, encoding: .utf8)
    }

    private func pendingCommandKey() -> RelayCommandKey? {
        let metadataURL = URL(fileURLWithPath: paths.metadata)
        return Self.relayCommandKey(from: try? Data(contentsOf: metadataURL))
    }

    private func touchPendingCommand() {
        let touchedAt = now()
        for path in [paths.command, paths.metadata] where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes([.modificationDate: touchedAt], ofItemAtPath: path)
        }
    }

    private static func relayCommandKey(from data: Data?) -> RelayCommandKey? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = relayCommandKey(from: object) else {
            return nil
        }
        return key
    }

    private static func relayCommandKey(from object: [String: Any]) -> RelayCommandKey? {
        guard
              let seq = relayCommandSeq(object["relay_command_seq"]),
              let id = object["relay_command_id"] as? String,
              !id.isEmpty else {
            return nil
        }
        let provider = (object["provider"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intentID = (object["intent_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RelayCommandKey(
            seq: seq,
            id: id,
            provider: provider?.isEmpty == false ? provider : nil,
            intentID: intentID?.isEmpty == false ? intentID : nil
        )
    }

    private static func relayCommandSeq(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func recordDeliveryEvent(
        _ event: String,
        key: RelayCommandKey?,
        fields: [String: Any] = [:]
    ) {
        deliveryOrder += 1
        var payload: [String: Any] = [
            "event": event,
            "order": deliveryOrder,
            "timestamp": now().timeIntervalSince1970,
        ]
        for (name, value) in fields {
            payload[name] = value
        }
        if let key {
            payload["relay_command_seq"] = key.seq
            payload["relay_command_id"] = key.id
            if let intentID = key.intentID {
                payload["intent_id"] = intentID
            }
        }
        let provider = key?.provider
            ?? ProcessInfo.processInfo.environment["RELAY_RUNNER_PROVIDER"]
        if let provider,
           !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["provider"] = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let lineData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: lineData, encoding: .utf8) else {
            return
        }
        appendBoundedLine(line, to: URL(fileURLWithPath: paths.deliveryEvents), limit: 128)
        if let key {
            recordDurableDeliveryDiagnostic(event, key: key, fields: fields)
        }
        let durableState: String?
        switch event {
        case "claimed", "claim_published", "provider_acknowledged":
            durableState = "claimed"
        case "stale_command_dropped", "stale_prompt_cleared":
            durableState = "superseded"
        case "terminal_failure", "delivery_failure_published",
             "delivery_failure_publish_failed":
            durableState = "delivery_failed"
        default:
            durableState = nil
        }
        if let durableState, let key {
            recordDurableActionState(durableState, key: key)
        }
    }

    private func appendBoundedLine(_ line: String, to url: URL, limit: Int) {
        var lines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            lines = existing.split(separator: "\n").map(String.init)
        }
        lines.append(line)
        lines = Array(lines.suffix(max(1, limit)))
        let contents = lines.joined(separator: "\n") + "\n"
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func recordDurableActionState(_ state: String, key: RelayCommandKey) {
        let url = URL(fileURLWithPath: paths.actionJournal)
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        var payload: [String: Any] = [
            "timestamp": now().timeIntervalSince1970,
            "relay_command_seq": key.seq,
            "relay_command_id": key.id,
            "state": state,
        ]
        if let provider = key.provider {
            payload["provider"] = provider
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        appendBoundedLine(line, to: url, limit: 200)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func recordDurableDeliveryDiagnostic(
        _ deliveryState: String,
        key: RelayCommandKey,
        fields: [String: Any]
    ) {
        let allowedFields = Set([
            "attempt",
            "barrier_elapsed_ms",
            "deferral_reason",
            "elapsed_ms",
            "pending_byte_count",
            "provider_turn_state",
            "provider_session_id",
            "provider_native_session_id",
            "provider_native_turn_id",
            "provider_turn_age_ms",
            "provider_turn_origin",
            "provider_turn_provider",
            "provider_turn_record_state",
            "provider_turn_release_reason",
        ])
        let safeFields = fields.filter { allowedFields.contains($0.key) }
        let url = URL(fileURLWithPath: paths.actionJournal)
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var payload: [String: Any] = [
            "timestamp": now().timeIntervalSince1970,
            "relay_command_seq": key.seq,
            "relay_command_id": key.id,
            "state": "delivery_diagnostic",
            "delivery_state": deliveryState,
        ]
        for (name, value) in safeFields { payload[name] = value }
        if let provider = key.provider { payload["provider"] = provider }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        appendBoundedLine(line, to: url, limit: 200)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func touchHeartbeat() {
        if fileManager.fileExists(atPath: paths.heartbeat) {
            try? fileManager.setAttributes(
                [.modificationDate: now()],
                ofItemAtPath: paths.heartbeat
            )
        } else {
            _ = fileManager.createFile(atPath: paths.heartbeat, contents: Data())
        }
    }
}

final class EmbeddedAgentDiagnostics {
    static let diagnosticsDirectoryName = "embedded-agent-diagnostics"
    static let manifestFilename = "current-session.json"
    static let schemaVersion = 4
    static let retainedAttemptLimit = 20

    private static var defaultBaseDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("relay-runner", isDirectory: true)
    }

    private let directoryURL: URL
    private let currentManifestURL: URL
    private let attemptManifestURL: URL
    let eventsURL: URL
    private let attemptID: String
    private let provider: String
    private let workingDirectory: String
    private let routeKind: String
    private let projectIdentity: String?
    private let startedAt: Date
    private let now: () -> Date
    private let queue = DispatchQueue(label: "relay-runner.embedded-agent-diagnostics")
    private var childPID: Int?
    private var state = "starting"
    private var currentStage = "launch_request"
    private var failedStage: String?
    private var endedAt: Date?
    private var rawStatus: Int32?

    static func diagnosticsDirectoryURL(baseDirectory: URL = defaultBaseDirectory) -> URL {
        baseDirectory.appendingPathComponent(diagnosticsDirectoryName, isDirectory: true)
    }

    static func manifestURL(baseDirectory: URL = defaultBaseDirectory) -> URL {
        diagnosticsDirectoryURL(baseDirectory: baseDirectory)
            .appendingPathComponent(manifestFilename, isDirectory: false)
    }

    static func start(
        provider: String,
        workingDirectory: String,
        baseDirectory: URL = defaultBaseDirectory,
        routeKind: String? = nil,
        projectIdentity: String? = nil,
        now: @escaping () -> Date = Date.init
    ) -> EmbeddedAgentDiagnostics? {
        finalizeInterruptedSessionIfNeeded(baseDirectory: baseDirectory, now: now())
        let resolvedRoute = routeKind.map { ($0, projectIdentity) }
            ?? routeContext(for: workingDirectory)
        let diagnostics = EmbeddedAgentDiagnostics(
            baseDirectory: baseDirectory,
            provider: provider,
            workingDirectory: workingDirectory,
            routeKind: resolvedRoute.0,
            projectIdentity: resolvedRoute.1,
            now: now,
        )
        return diagnostics.prepare() ? diagnostics : nil
    }

    static func finalizeInterruptedSessionIfNeeded(
        baseDirectory: URL = defaultBaseDirectory,
        now: Date = Date()
    ) {
        let currentURL = manifestURL(baseDirectory: baseDirectory)
        guard let data = try? Data(contentsOf: currentURL),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = payload["state"] as? String,
              !["exited", "provider_early_exit", "setup_failed", "app_requested_stop", "app_relaunch"].contains(state)
        else { return }

        payload["state"] = "app_relaunch"
        payload["current_stage"] = "session_failure"
        payload["ended_at"] = format(now)
        payload["failure_kind"] = "app_relaunch"
        guard let updated = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? updated.write(to: currentURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: currentURL.path
        )
        if let attemptPath = payload["attempt_manifest_path"] as? String {
            let attemptURL = URL(fileURLWithPath: attemptPath)
            try? updated.write(to: attemptURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: attemptURL.path
            )
        }
    }

    private init(
        baseDirectory: URL,
        provider: String,
        workingDirectory: String,
        routeKind: String,
        projectIdentity: String?,
        now: @escaping () -> Date,
    ) {
        attemptID = UUID().uuidString.lowercased()
        directoryURL = Self.diagnosticsDirectoryURL(baseDirectory: baseDirectory)
        currentManifestURL = Self.manifestURL(baseDirectory: baseDirectory)
        attemptManifestURL = directoryURL
            .appendingPathComponent("\(attemptID).json", isDirectory: false)
        eventsURL = directoryURL
            .appendingPathComponent("\(attemptID).events.jsonl", isDirectory: false)
        self.provider = provider
        self.workingDirectory = workingDirectory
        self.routeKind = routeKind
        self.projectIdentity = projectIdentity
        self.now = now
        self.startedAt = now()
    }

    func markLauncherPrepared(path: String) {
        queue.sync { [self] in
            currentStage = "launcher_prepared"
            appendEvent(stage: currentStage, outcome: "success", fields: ["launcher_path": path])
            try? writeManifest()
        }
    }

    func recordChildPID(_ childPID: Int?) {
        queue.async { [self] in
            self.childPID = childPID
            try? writeManifest()
        }
    }

    func markInteractiveReady() {
        queue.async { [self] in
            state = "ready"
            currentStage = "interactive_provider_readiness"
            appendEvent(
                stage: currentStage,
                outcome: "ready",
                fields: ["controlling_pty": "stable"]
            )
            try? writeManifest()
        }
    }

    func markExited(rawStatus: Int32?, beforeInteractiveReadiness: Bool) {
        queue.async { [self] in
            self.rawStatus = rawStatus
            endedAt = now()
            state = beforeInteractiveReadiness ? "provider_early_exit" : "exited"
            failedStage = beforeInteractiveReadiness
                ? "interactive_provider_readiness"
                : nil
            currentStage = beforeInteractiveReadiness ? "session_failure" : "session_end"
            var fields = Self.terminationFields(rawStatus)
            if let failedStage {
                fields["failed_stage"] = failedStage
            }
            appendEvent(
                stage: currentStage,
                outcome: state,
                fields: fields
            )
            try? writeManifest()
        }
    }

    func markLaunchFailed(rawStatus: Int32?) {
        queue.async { [self] in
            self.rawStatus = rawStatus
            endedAt = now()
            state = "setup_failed"
            currentStage = "session_failure"
            appendEvent(
                stage: currentStage,
                outcome: "launcher_exit_before_provider_spawn",
                fields: Self.terminationFields(rawStatus)
            )
            try? writeManifest()
        }
    }

    func markSetupFailed(message: String) {
        queue.async { [self] in
            _ = message
            endedAt = now()
            state = "setup_failed"
            currentStage = "session_failure"
            appendEvent(stage: currentStage, outcome: "setup_failed")
            try? writeManifest()
        }
    }

    func markAppRequestedStop() {
        queue.async { [self] in
            endedAt = now()
            state = "app_requested_stop"
            currentStage = "session_end"
            appendEvent(stage: currentStage, outcome: "app_requested_stop")
            try? writeManifest()
        }
    }

    func flushForTesting() {
        queue.sync {}
    }

    func recordedOutcome(for stage: String) -> String? {
        queue.sync {
            guard let contents = try? String(contentsOf: eventsURL, encoding: .utf8) else {
                return nil
            }
            return contents
                .split(separator: "\n")
                .compactMap { line -> [String: Any]? in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                .last { $0["stage"] as? String == stage }?["outcome"] as? String
        }
    }

    private func prepare() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: ownerOnlyDirectoryAttributes
            )
            try setOwnerOnlyPermissions(at: directoryURL, permissions: 0o700)
            try Data().write(to: eventsURL, options: .atomic)
            try setOwnerOnlyPermissions(at: eventsURL, permissions: 0o600)
            appendEvent(stage: currentStage, outcome: "requested")
            try writeManifest()
            pruneOldAttempts()
            return true
        } catch {
            return false
        }
    }

    private func appendEvent(
        stage: String,
        outcome: String,
        fields: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "timestamp": Self.format(now()),
            "stage": stage,
            "outcome": outcome,
        ]
        for (key, value) in fields {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var existing = (try? Data(contentsOf: eventsURL)) ?? Data()
        existing.append(data)
        existing.append(0x0a)
        try? existing.write(to: eventsURL, options: .atomic)
        try? setOwnerOnlyPermissions(at: eventsURL, permissions: 0o600)
    }

    private func writeManifest() throws {
        var payload: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "attempt_id": attemptID,
            "provider": provider,
            "configured_workspace_folder": workingDirectory,
            "route_kind": routeKind,
            "started_at": Self.format(startedAt),
            "state": state,
            "current_stage": currentStage,
            "events_path": eventsURL.path,
            "attempt_manifest_path": attemptManifestURL.path,
        ]
        if let childPID {
            payload["child_pid"] = childPID
        }
        if let projectIdentity {
            payload["project_identity"] = projectIdentity
        }
        if let endedAt {
            payload["ended_at"] = Self.format(endedAt)
        }
        if let rawStatus {
            payload["raw_exit_status"] = rawStatus
            for (key, value) in Self.terminationFields(rawStatus) {
                payload[key] = value
            }
        }
        if let failedStage {
            payload["failed_stage"] = failedStage
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        for url in [currentManifestURL, attemptManifestURL] {
            try data.write(to: url, options: .atomic)
            try setOwnerOnlyPermissions(at: url, permissions: 0o600)
        }
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func terminationFields(_ rawStatus: Int32?) -> [String: Any] {
        guard let rawStatus else { return [:] }
        let signalBits = rawStatus & 0x7f
        if signalBits == 0 {
            return ["exit_code": (rawStatus >> 8) & 0xff]
        }
        return ["termination_signal": signalBits]
    }

    private static func routeContext(for workingDirectory: String) -> (String, String?) {
        do {
            switch try ProjectRegistry().classifyDiscoveryRoot(
                at: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            ) {
            case .workspaceRoot(let rootPath, _):
                return ("workspace_root", rootPath.path)
            case .singleProject(let repoPath):
                return ("project", repoPath.path)
            }
        } catch {
            return ("unavailable", nil)
        }
    }

    private func pruneOldAttempts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let manifests = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.manifestFilename }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return lhs > rhs
            }
        for manifest in manifests.dropFirst(Self.retainedAttemptLimit) {
            let eventName = manifest.deletingPathExtension().lastPathComponent + ".events.jsonl"
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(eventName)
            )
            try? FileManager.default.removeItem(at: manifest)
        }
    }

    private var ownerOnlyDirectoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: NSNumber(value: Int16(0o700))]
    }

    private func setOwnerOnlyPermissions(at url: URL, permissions: Int16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}

final class SwiftTermEmbeddedProcess: EmbeddedTerminalProcess, TerminalViewDelegate, LocalProcessDelegate {
    static let defaultReadinessStabilityInterval: TimeInterval = 1.0
    static let defaultReadinessPollInterval: TimeInterval = 0.05

    let terminalView: RelayTerminalView
    lazy var localProcess = LocalProcess(delegate: self)
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    var onTitle: ((String) -> Void)?
    private var voiceDelivery: RelayVoiceCommandDelivery?
    private var sessionEventPath: String?
    private var readinessScheduled = false
    private var interactiveReady = false
    private var stableTerminalSince: UInt64?
    private let readinessStabilityInterval: TimeInterval
    private let readinessPollInterval: TimeInterval
    private let voiceDeliveryPaths: RelayVoiceCommandDelivery.Paths
    private let voiceDeliveryAcknowledgementTimeout: TimeInterval

    init(
        readinessStabilityInterval: TimeInterval =
            SwiftTermEmbeddedProcess.defaultReadinessStabilityInterval,
        readinessPollInterval: TimeInterval =
            SwiftTermEmbeddedProcess.defaultReadinessPollInterval,
        voiceDeliveryPaths: RelayVoiceCommandDelivery.Paths = .init(),
        voiceDeliveryAcknowledgementTimeout: TimeInterval = 2.0
    ) {
        self.readinessStabilityInterval = max(0, readinessStabilityInterval)
        self.readinessPollInterval = max(0.01, readinessPollInterval)
        self.voiceDeliveryPaths = voiceDeliveryPaths
        self.voiceDeliveryAcknowledgementTimeout = max(0.01, voiceDeliveryAcknowledgementTimeout)
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
    var hasStableInteractiveTerminal: Bool {
        let descriptor = localProcess.childfd
        let pid = localProcess.shellPid
        guard localProcess.running,
              descriptor >= 0,
              pid > 0,
              isatty(descriptor) == 1,
              Darwin.kill(pid, 0) == 0 || errno == EPERM else {
            return false
        }

        let foregroundProcessGroup = tcgetpgrp(descriptor)
        let providerProcessGroup = getpgid(pid)
        guard foregroundProcessGroup > 0,
              providerProcessGroup > 0,
              providerProcessGroup == foregroundProcessGroup else {
            return false
        }

        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { return false }
        return attributes.c_lflag & tcflag_t(ICANON) == 0
    }
    var hasFocus: Bool { terminalView.hasFocus }
    var childPID: Int? {
        let pid = Int(localProcess.shellPid)
        return pid > 0 ? pid : nil
    }

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        voiceDelivery?.stop()
        voiceDelivery = nil
        readinessScheduled = false
        interactiveReady = false
        stableTerminalSince = nil
        sessionEventPath = launch.sessionEventPath
        localProcess.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: Self.terminalEnvironment(correlationID: launch.diagnosticsCorrelationID),
            currentDirectory: launch.workingDirectory
        )
        guard localProcess.running else { throw EmbeddedTerminalProcessError.couldNotStart }
        if launch.voiceDelivery == .appOwned {
            let transportSend: RelayVoiceCommandDelivery.TransportSend = { [weak self] data, confirmation in
                let bytes = Array(data)
                DispatchQueue.main.async { [weak self] in
                    self?.localProcess.send(data: ArraySlice(bytes))
                    confirmation()
                }
            }
            let delivery = RelayVoiceCommandDelivery(
                paths: voiceDeliveryPaths,
                send: { data in
                    transportSend(data) {}
                },
                transportSend: transportSend,
                acknowledgementTimeout: voiceDeliveryAcknowledgementTimeout,
                isRunning: { [weak self] in
                    self?.localProcess.running == true
                },
                providerSessionID: launch.providerSessionID
            )
            voiceDelivery = delivery
        }
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func terminate() {
        readinessScheduled = false
        stableTerminalSince = nil
        voiceDelivery?.providerProcessTerminated(releaseReason: "app_teardown")
        voiceDelivery = nil
        localProcess.terminate()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !terminalView.isSendingTerminalResponse,
           !terminalView.isSendingNavigationShortcut,
           voiceDelivery?.recordUserInput(data) == false {
            return
        }
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
        considerInteractiveReadiness(after: slice)
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
        readinessScheduled = false
        stableTerminalSince = nil
        voiceDelivery?.providerProcessTerminated()
        voiceDelivery = nil
        onExit?(exitCode)
    }

    private func considerInteractiveReadiness(after output: ArraySlice<UInt8>) {
        guard !output.isEmpty,
              !readinessScheduled,
              !interactiveReady,
              localProcess.running,
              let sessionEventPath,
              let events = try? String(contentsOfFile: sessionEventPath, encoding: .utf8),
              events.contains(#""stage": "provider_spawn""#)
                || events.contains(#""stage":"provider_spawn""#)
        else { return }

        readinessScheduled = true
        observeInteractiveReadiness()
    }

    private func observeInteractiveReadiness() {
        guard readinessScheduled,
              !interactiveReady,
              localProcess.running else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if hasStableInteractiveTerminal {
            let stableSince = stableTerminalSince ?? now
            self.stableTerminalSince = stableSince
            let stableDuration = Double(now - stableSince) / 1_000_000_000
            if stableDuration >= readinessStabilityInterval {
                readinessScheduled = false
                interactiveReady = true
                // App-owned commands must not enter the PTY while its child is
                // still the bridge/bootstrap launcher. The foreground raw TTY
                // is the provider-owned handoff boundary.
                voiceDelivery?.start()
                onReady?()
                return
            }
        } else {
            stableTerminalSince = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + readinessPollInterval) { [weak self] in
            self?.observeInteractiveReadiness()
        }
    }

    private static func terminalEnvironment(correlationID: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["RELAY_APP_SESSION_ID"] = RelayDiagnostics.shared.appSessionID
        environment["RELAY_CORRELATION_ID"] = correlationID
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
        case .starting: return "Starting \(session.providerName)"
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
            return "This Relay session is running in Terminal.app. Use the Workspace session control to end it before starting an embedded session."
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
            workingDirectory: resolvedWorkingDirectory
        )
    }

    private var resolvedWorkingDirectory: String {
        let override = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = override.isEmpty ? appState.config.general.working_directory : override
        return WorkspaceFolder.url(from: configured).path
    }
}
