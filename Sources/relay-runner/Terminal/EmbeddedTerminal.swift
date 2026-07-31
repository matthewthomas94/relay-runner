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
                } else if exitedBeforeReadiness {
                    self.diagnostics?.markExited(
                        rawStatus: rawStatus,
                        beforeInteractiveReadiness: true
                    )
                    self.phase = .failed(Self.earlyExitMessage(
                        providerName: self.providerName,
                        rawStatus: rawStatus
                    ))
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
    private(set) var pendingByteCount = 0

    var hasUnsubmittedInput: Bool { pendingByteCount > 0 }

    mutating func record(data: ArraySlice<UInt8>) {
        if recordKittyKeyEvent(data) { return }
        if isNavigationShortcut(data) { return }

        for byte in data {
            switch byte {
            case 3, 21:
                // Ctrl-C / Ctrl-U clears a partial prompt in both Codex and Claude.
                pendingByteCount = 0
            case 10, 13:
                pendingByteCount = 0
            case 8, 127:
                pendingByteCount = max(0, pendingByteCount - 1)
            case 9, 32...126:
                pendingByteCount += 1
            default:
                break
            }
        }
    }

    private func isNavigationShortcut(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        return bytes == [27, 98] || bytes == [27, 102] || bytes == [1] || bytes == [5]
    }

    private mutating func recordKittyKeyEvent(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 4,
              data[data.startIndex] == 27,
              data[data.index(after: data.startIndex)] == 91,
              data[data.index(before: data.endIndex)] == 117 else {
            return false
        }

        let bodyStart = data.index(data.startIndex, offsetBy: 2)
        let bodyEnd = data.index(before: data.endIndex)
        let fields = String(decoding: data[bodyStart..<bodyEnd], as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        guard let keyField = fields.first,
              let keyCode = Int(keyField.split(separator: ":", omittingEmptySubsequences: false)[0]) else {
            return false
        }

        let modifierField = fields.count > 1 ? fields[1] : ""
        let modifierParts = modifierField.split(separator: ":", omittingEmptySubsequences: false)
        let modifierMask = max(0, (Int(modifierParts.first ?? "") ?? 1) - 1)
        let eventType = modifierParts.count > 1 ? Int(modifierParts[1]) ?? 1 : 1
        if eventType == 3 { return true }

        let controlIsPressed = modifierMask & 4 != 0
        if controlIsPressed {
            if keyCode == 99 || keyCode == 117 {
                pendingByteCount = 0
            }
            return true
        }

        switch keyCode {
        case 3, 10, 13, 21:
            pendingByteCount = 0
        case 8, 127:
            pendingByteCount = max(0, pendingByteCount - 1)
        case 9:
            pendingByteCount += 1
        case 32...0x10ffff where !(0xe000...0xf8ff).contains(keyCode):
            pendingByteCount += 1
        default:
            break
        }
        return true
    }
}

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

        static func == (lhs: RelayCommandKey, rhs: RelayCommandKey) -> Bool {
            lhs.seq == rhs.seq && lhs.id == rhs.id
        }
    }

    private struct PendingSubmission: Equatable {
        let key: RelayCommandKey
        let events: [[UInt8]]
        var attempts: Int
    }

    typealias Send = (ArraySlice<UInt8>) -> Void
    typealias Schedule = (TimeInterval, DispatchQueue, @escaping () -> Void) -> Void

    private let paths: Paths
    private let send: Send
    private let schedule: Schedule
    private let submitDelay: TimeInterval
    private let acknowledgementTimeout: TimeInterval
    private let maxSubmitAttempts: Int
    private let isRunning: () -> Bool
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "relay-runner.voice-command-delivery")
    private var timer: DispatchSourceTimer?
    private var inputTracker = RelayTerminalInputTracker()
    private var submitInFlight = false
    private var pendingSubmission: PendingSubmission?
    private var deliveryOrder = 0
    private var lastDeferredProviderActiveKey: RelayCommandKey?

    init(
        paths: Paths = Paths(),
        send: @escaping Send,
        submitDelay: TimeInterval = 0.12,
        acknowledgementTimeout: TimeInterval = 2.0,
        maxSubmitAttempts: Int = 2,
        schedule: @escaping Schedule = { delay, queue, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        },
        isRunning: @escaping () -> Bool,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.send = send
        self.submitDelay = submitDelay
        self.acknowledgementTimeout = acknowledgementTimeout
        self.maxSubmitAttempts = max(1, maxSubmitAttempts)
        self.schedule = schedule
        self.isRunning = isRunning
        self.fileManager = fileManager
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

    func recordUserInput(_ data: ArraySlice<UInt8>) {
        queue.async { [weak self] in
            self?.inputTracker.record(data: data)
        }
    }

    @discardableResult
    func claimAndSendIfPossible() -> Bool {
        touchHeartbeat()
        if completePendingSubmissionIfAcknowledged() {
            return true
        }
        guard isRunning(),
              !submitInFlight,
              pendingSubmission == nil,
              !inputTracker.hasUnsubmittedInput,
              providerReadyForNextCommand() else { return false }
        lastDeferredProviderActiveKey = nil
        guard let command = claimNextCommand() else { return false }
        guard var events = Self.providerInputEvents(for: command.text) else { return true }
        if providerTurnActive(),
           Self.metadataRequestsProviderPreemption(command.metadata),
           events.first != [3] {
            events.insert([3], at: 0)
        }
        guard let first = events.first else { return true }
        let key = Self.relayCommandKey(from: command.metadata)
        if let key, !isCommandCurrent(key) {
            recordDeliveryEvent("stale_command_dropped", key: key)
            return true
        }
        recordDeliveryEvent("claimed", key: key)
        if command.text.trimmingCharacters(in: .whitespacesAndNewlines) == "__INTERRUPT__",
           !providerTurnActive() {
            writeClaimedMetadata(command.metadata)
            writeConsumerAcknowledgement(command.metadata)
            recordDeliveryEvent("claim_published", key: key)
            return true
        }
        send(ArraySlice(first))
        recordDeliveryEvent("prompt_write", key: key)
        guard events.count > 1 else {
            writeClaimedMetadata(command.metadata)
            // One-event controls do not produce a provider hook turn, so the
            // terminal consumer must acknowledge them to release the inbox.
            writeConsumerAcknowledgement(command.metadata)
            recordDeliveryEvent("claim_published", key: key)
            return true
        }
        submitInFlight = true
        let remaining = Array(events.dropFirst())
        schedule(submitDelay, queue) { [weak self] in
            guard let self else { return }
            defer { self.submitInFlight = false }
            guard self.isRunning() else {
                if let key {
                    self.recordDeliveryEvent("submit_aborted_not_running", key: key, fields: ["attempt": 0])
                    let published = self.publishDeliveryFailure(for: key)
                    self.recordDeliveryEvent(
                        published ? "delivery_failure_published" : "delivery_failure_publish_failed",
                        key: key
                    )
                }
                return
            }
            self.touchHeartbeat()
            if let key, !self.isCommandCurrent(key) {
                self.send(ArraySlice([21]))
                self.recordDeliveryEvent("stale_prompt_cleared", key: key)
                return
            }
            self.writeClaimedMetadata(command.metadata)
            self.recordDeliveryEvent("claim_published", key: key)
            guard let key else {
                for event in remaining {
                    self.send(ArraySlice(event))
                    self.recordDeliveryEvent("submit_attempt", key: nil)
                }
                return
            }
            self.pendingSubmission = PendingSubmission(key: key, events: remaining, attempts: 0)
            self.sendPendingSubmissionAttempt()
        }
        return true
    }

    private func providerReadyForNextCommand() -> Bool {
        guard providerTurnActive() else { return true }
        if pendingCommandRequestsProviderPreemption() {
            return true
        }
        guard let text = peekPendingCommandText() else { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "__INTERRUPT__" {
            return true
        }
        touchPendingCommand()
        let key = pendingCommandKey()
        if key != lastDeferredProviderActiveKey {
            recordDeliveryEvent("deferred_provider_active", key: key)
            lastDeferredProviderActiveKey = key
        }
        return false
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
        return Self.metadataRequestsProviderPreemption(try? Data(contentsOf: metadataURL))
    }

    private static func metadataRequestsProviderPreemption(_ data: Data?) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if object["preempt_provider"] as? Bool == true {
            return true
        }
        let disposition = object["work_disposition"] as? [String: Any]
        return disposition?["route"] as? String == "replace_current"
    }

    private func providerTurnActive() -> Bool {
        let turnsURL = URL(fileURLWithPath: paths.providerTurns)
        guard let data = try? Data(contentsOf: turnsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else {
            return false
        }
        return records.contains { record in
            (record["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        }
    }

    private func providerTurnState(for key: RelayCommandKey) -> String? {
        let turnsURL = URL(fileURLWithPath: paths.providerTurns)
        guard let data = try? Data(contentsOf: turnsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else {
            return nil
        }
        for record in records.reversed() where Self.relayCommandKey(from: record) == key {
            let state = (record["state"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return state?.isEmpty == false ? state : nil
        }
        return nil
    }

    @discardableResult
    private func completePendingSubmissionIfAcknowledged() -> Bool {
        guard let pending = pendingSubmission,
              let state = providerTurnState(for: pending.key),
              state != "stale" else {
            return false
        }
        recordDeliveryEvent(
            "provider_acknowledged",
            key: pending.key,
            fields: ["attempt": pending.attempts, "provider_turn_state": state]
        )
        pendingSubmission = nil
        return true
    }

    private func sendPendingSubmissionAttempt() {
        guard var pending = pendingSubmission else { return }
        guard isRunning() else {
            failPendingSubmission(pending, event: "submit_aborted_not_running")
            return
        }
        pending.attempts += 1
        pendingSubmission = pending
        if pending.attempts > 1 {
            recordDeliveryEvent("submit_retry", key: pending.key, fields: ["attempt": pending.attempts])
        }
        for event in pending.events {
            send(ArraySlice(event))
            recordDeliveryEvent("submit_attempt", key: pending.key, fields: ["attempt": pending.attempts])
        }
        schedule(acknowledgementTimeout, queue) { [weak self] in
            self?.handleAcknowledgementTimeout(for: pending.key, attempt: pending.attempts)
        }
    }

    private func handleAcknowledgementTimeout(for key: RelayCommandKey, attempt: Int) {
        touchHeartbeat()
        guard let pending = pendingSubmission,
              pending.key == key,
              pending.attempts == attempt else {
            return
        }
        if completePendingSubmissionIfAcknowledged() {
            return
        }
        guard isRunning() else {
            failPendingSubmission(pending, event: "submit_aborted_not_running")
            return
        }
        if !isCommandCurrent(key) {
            if providerTurnActive() {
                recordDeliveryEvent("stale_ack_wait_provider_active", key: key, fields: ["attempt": attempt])
                schedule(min(acknowledgementTimeout, 0.5), queue) { [weak self] in
                    self?.handleAcknowledgementTimeout(for: key, attempt: attempt)
                }
            } else {
                send(ArraySlice([21]))
                recordDeliveryEvent("stale_prompt_cleared", key: key, fields: ["attempt": attempt])
                pendingSubmission = nil
            }
            return
        }
        if providerTurnActive() {
            recordDeliveryEvent("submit_ack_wait_provider_active", key: key, fields: ["attempt": attempt])
            schedule(min(acknowledgementTimeout, 0.5), queue) { [weak self] in
                self?.handleAcknowledgementTimeout(for: key, attempt: attempt)
            }
            return
        }
        recordDeliveryEvent("submit_ack_timeout", key: key, fields: ["attempt": attempt])
        if attempt < maxSubmitAttempts {
            sendPendingSubmissionAttempt()
            return
        }
        send(ArraySlice([21]))
        recordDeliveryEvent("submit_recovery_clear", key: key, fields: ["attempt": attempt])
        failPendingSubmission(pending, event: "submit_ack_failed")
    }

    private func failPendingSubmission(_ pending: PendingSubmission, event: String) {
        recordDeliveryEvent(event, key: pending.key, fields: ["attempt": pending.attempts])
        let published = publishDeliveryFailure(for: pending.key)
        recordDeliveryEvent(
            published ? "delivery_failure_published" : "delivery_failure_publish_failed",
            key: pending.key
        )
        pendingSubmission = nil
    }

    @discardableResult
    private func publishDeliveryFailure(for key: RelayCommandKey) -> Bool {
        var payload: [String: Any] = [
            "text": "The voice command was not delivered to the provider, so I cleared the terminal prompt before it could run accidentally. Please try that command again.",
            "relay_command_seq": key.seq,
            "relay_command_id": key.id,
        ]
        if let provider = key.provider {
            payload["provider"] = provider
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
        let now = Date()
        for path in [paths.command, paths.metadata] where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: path)
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
        return RelayCommandKey(seq: seq, id: id, provider: provider?.isEmpty == false ? provider : nil)
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
            "timestamp": Date().timeIntervalSince1970,
        ]
        for (name, value) in fields {
            payload[name] = value
        }
        if let key {
            payload["relay_command_seq"] = key.seq
            payload["relay_command_id"] = key.id
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
        let durableState: String?
        switch event {
        case "claimed", "claim_published", "provider_acknowledged":
            durableState = "claimed"
        case "stale_command_dropped", "stale_prompt_cleared":
            durableState = "superseded"
        case "submit_ack_failed", "submit_aborted_not_running",
             "delivery_failure_published", "delivery_failure_publish_failed":
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
            "timestamp": Date().timeIntervalSince1970,
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

    private func touchHeartbeat() {
        if fileManager.fileExists(atPath: paths.heartbeat) {
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
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

    init(
        readinessStabilityInterval: TimeInterval =
            SwiftTermEmbeddedProcess.defaultReadinessStabilityInterval,
        readinessPollInterval: TimeInterval =
            SwiftTermEmbeddedProcess.defaultReadinessPollInterval,
        voiceDeliveryPaths: RelayVoiceCommandDelivery.Paths = .init()
    ) {
        self.readinessStabilityInterval = max(0, readinessStabilityInterval)
        self.readinessPollInterval = max(0.01, readinessPollInterval)
        self.voiceDeliveryPaths = voiceDeliveryPaths
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
            environment: Self.terminalEnvironment(),
            currentDirectory: launch.workingDirectory
        )
        guard localProcess.running else { throw EmbeddedTerminalProcessError.couldNotStart }
        if launch.voiceDelivery == .appOwned {
            let delivery = RelayVoiceCommandDelivery(
                paths: voiceDeliveryPaths,
                send: { [weak self] data in
                    let bytes = Array(data)
                    DispatchQueue.main.async { [weak self] in
                        self?.localProcess.send(data: ArraySlice(bytes))
                    }
                },
                isRunning: { [weak self] in
                    self?.localProcess.running == true
                }
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
        voiceDelivery?.stop()
        voiceDelivery = nil
        localProcess.terminate()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !terminalView.isSendingTerminalResponse,
           !terminalView.isSendingNavigationShortcut {
            voiceDelivery?.recordUserInput(data)
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
        voiceDelivery?.stop()
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
