import CryptoKit
import Darwin
import Foundation

struct ContinuityRecoveryRequest: Equatable {
    let capability: String
    let incidentID: String
    let sessionID: String
    let commandID: String?
    let component: String
    let provider: String
    let recoveryGeneration: String
    let incidentPhase: String
    let processIdentity: String
    let attempt: Int
    let idempotencyKey: String
    let expectedPostcondition: String
    let incidentObservedAt: Double
    let deadline: Double
    let validationToken: String
    let exactTargetOwned: Bool
    let liveness: String
    let incidentActive: Bool
    let generationMatches: Bool
    let commandPhase: String
    let commandPhaseMatches: Bool
    let idempotencyState: String
    let compensationAvailable: Bool
    let cooldownRemaining: Double

    init?(_ json: [String: Any]) {
        guard
            let capability = Self.code(json["capability"]),
            let incidentID = Self.identifier(json["incident_id"], pattern: #"^inc-[0-9a-f]{12}$"#),
            let sessionID = Self.identifier(
                json["session_id"], pattern: #"^session-[0-9a-f]{24}$"#
            ),
            let component = Self.code(json["component"]),
            let provider = json["provider"] as? String,
            ["none", "codex", "claude"].contains(provider),
            let recoveryGeneration = Self.generation(json["recovery_generation"]),
            let incidentPhase = Self.code(json["incident_phase"]),
            let processIdentity = Self.identifier(
                json["process_identity"], pattern: #"^continuity-[0-9a-f]{32}$"#
            ),
            let attempt = json["attempt"] as? Int,
            attempt >= 1,
            let idempotencyKey = Self.identifier(
                json["idempotency_key"], pattern: #"^recovery_[0-9a-f]{24}$"#
            ),
            let expectedPostcondition = Self.code(json["expected_postcondition"]),
            let incidentObservedAt = Self.number(json["incident_observed_at"]),
            incidentObservedAt.isFinite,
            let deadline = Self.number(json["deadline"]),
            deadline.isFinite,
            let validationToken = Self.code(json["validation_token"]),
            let exactTargetOwned = json["exact_target_owned"] as? Bool,
            let liveness = Self.code(json["liveness"]),
            let incidentActive = json["incident_active"] as? Bool,
            let generationMatches = json["generation_matches"] as? Bool,
            let commandPhase = Self.code(json["command_phase"]),
            let commandPhaseMatches = json["command_phase_matches"] as? Bool,
            let idempotencyState = Self.code(json["idempotency_state"]),
            let compensationAvailable = json["compensation_available"] as? Bool,
            let cooldownRemaining = Self.number(json["cooldown_remaining"]),
            cooldownRemaining.isFinite,
            cooldownRemaining >= 0
        else { return nil }

        let commandID: String?
        if json["command_id"] is NSNull || json["command_id"] == nil {
            commandID = nil
        } else {
            guard let parsed = Self.identifier(
                json["command_id"], pattern: #"^command-[0-9a-f]{24}$"#
            ) else {
                return nil
            }
            commandID = parsed
        }

        self.capability = capability
        self.incidentID = incidentID
        self.sessionID = sessionID
        self.commandID = commandID
        self.component = component
        self.provider = provider
        self.recoveryGeneration = recoveryGeneration
        self.incidentPhase = incidentPhase
        self.processIdentity = processIdentity
        self.attempt = attempt
        self.idempotencyKey = idempotencyKey
        self.expectedPostcondition = expectedPostcondition
        self.incidentObservedAt = incidentObservedAt
        self.deadline = deadline
        self.validationToken = validationToken
        self.exactTargetOwned = exactTargetOwned
        self.liveness = liveness
        self.incidentActive = incidentActive
        self.generationMatches = generationMatches
        self.commandPhase = commandPhase
        self.commandPhaseMatches = commandPhaseMatches
        self.idempotencyState = idempotencyState
        self.compensationAvailable = compensationAvailable
        self.cooldownRemaining = cooldownRemaining
    }

    static func opaqueIdentifier(kind: String, nativeValue: String) -> String {
        let digest = SHA256.hash(data: Data("continuity-v1:\(kind):\(nativeValue)".utf8))
        return "\(kind)-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func projectSessionIdentifier(repositoryPath: String) -> String {
        let expandedPath = (repositoryPath as NSString).expandingTildeInPath
        let resolvedPath: String
        if let resolved = realpath(expandedPath, nil) {
            resolvedPath = String(cString: resolved)
            free(resolved)
        } else {
            resolvedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        }
        let digest = Insecure.SHA1.hash(data: Data(resolvedPath.utf8))
        let sessionKey = "project:" + digest.prefix(8).map {
            String(format: "%02x", $0)
        }.joined()
        return opaqueIdentifier(kind: "session", nativeValue: sessionKey)
    }

    static func idempotencyKey(
        incidentID: String,
        recoveryGeneration: String,
        capability: String,
        component: String,
        sessionID: String,
        commandID: String?
    ) -> String {
        let identity = [
            incidentID,
            recoveryGeneration,
            capability,
            component,
            sessionID,
            commandID ?? "none",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "recovery_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func code(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private static func generation(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(
                  of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        return value
    }

    private static func identifier(_ value: Any?, pattern: String) -> String? {
        guard let value = value as? String,
              value.range(of: pattern, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}

struct ContinuityRecoveryResponse: Equatable {
    let status: String
    let outcomeCode: String

    static func applied(_ code: String = "component_action_requested") -> Self {
        Self(status: "applied", outcomeCode: code)
    }

    static func failed(_ code: String) -> Self {
        Self(status: "failed", outcomeCode: code)
    }
}

/// Listens on /tmp/voice_state.sock for JSON state updates from Python services.
/// Dispatches parsed events to the StateMachine on the main actor.
actor StateEventBus {

    static let socketPath = "/tmp/voice_state.sock"

    private var fd: Int32 = -1
    private var receiveTask: Task<Void, Never>?
    private weak var stateMachine: StateMachine?
    private let shouldHandleServiceEvent: @MainActor (
        _ source: String,
        _ tutorial: Bool
    ) -> Bool
    private let onServiceEvent: @MainActor (
        _ source: String,
        _ state: String,
        _ text: String?,
        _ tutorial: Bool
    ) -> Void
    private let onRecoveryAction: @MainActor (
        _ request: ContinuityRecoveryRequest
    ) -> ContinuityRecoveryResponse

    init(
        stateMachine: StateMachine,
        shouldHandleServiceEvent: @escaping @MainActor (
            _ source: String,
            _ tutorial: Bool
        ) -> Bool = { _, _ in true },
        onServiceEvent: @escaping @MainActor (
            _ source: String,
            _ state: String,
            _ text: String?,
            _ tutorial: Bool
        ) -> Void = { _, _, _, _ in },
        onRecoveryAction: @escaping @MainActor (
            _ request: ContinuityRecoveryRequest
        ) -> ContinuityRecoveryResponse = { _ in
            .failed("component_action_unavailable")
        }
    ) {
        self.stateMachine = stateMachine
        self.shouldHandleServiceEvent = shouldHandleServiceEvent
        self.onServiceEvent = onServiceEvent
        self.onRecoveryAction = onRecoveryAction
    }

    func start() {
        stop()

        // Clean up stale socket
        unlink(StateEventBus.socketPath)

        // Create Unix datagram socket
        let sock = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            NSLog("[StateEventBus] Failed to create socket: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = StateEventBus.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            NSLog("[StateEventBus] Failed to bind socket: \(errno)")
            close(sock)
            return
        }

        self.fd = sock
        NSLog("[StateEventBus] Listening on \(StateEventBus.socketPath)")

        // Receive loop
        receiveTask = Task { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                guard let self else { return }
                let currentFd = await self.fd
                guard currentFd >= 0 else { return }

                // Use poll to avoid blocking indefinitely
                var pfd = pollfd(fd: currentFd, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, 200)  // 200ms timeout

                if pollResult <= 0 { continue }

                let n = recv(currentFd, &buffer, buffer.count, 0)
                guard n > 0 else { continue }

                let data = Data(bytes: buffer, count: n)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let source = json["source"] as? String,
                      let state = json["state"] as? String
                else { continue }

                let text = json["text"] as? String
                let tutorial = json["tutorial"] as? Bool ?? false
                let autoDismiss = json["auto_dismiss_seconds"] as? Double
                let presentation = SpeechPresentation(json)

                if source == "continuity_recovery", state == "request" {
                    let onRecoveryAction = await self.onRecoveryAction
                    let response = await MainActor.run {
                        guard let request = ContinuityRecoveryRequest(json) else {
                            return ContinuityRecoveryResponse.failed("invalid_recovery_context")
                        }
                        return onRecoveryAction(request)
                    }
                    if let replyPath = json["reply_path"] as? String,
                       replyPath.range(
                           of: #"^/tmp/relay_recovery_recovery_[0-9a-f]{24}\.json$"#,
                           options: .regularExpression
                       ) != nil {
                        let reply: [String: String] = [
                            "status": response.status,
                            "outcome_code": response.outcomeCode,
                        ]
                        if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
                            try? replyData.write(
                                to: URL(fileURLWithPath: replyPath),
                                options: .atomic
                            )
                        }
                    }
                    continue
                }

                let presentationLog = presentation.map {
                    " utterance=\($0.utteranceID) command_seq=\($0.commandSequence.map(String.init) ?? "none") command_id=\($0.commandID ?? "none") mode=\($0.mode.rawValue)"
                } ?? ""
                NSLog("[StateEventBus] \(source):\(state) has_text=\(text != nil)\(presentationLog)")

                let sm = await self.stateMachine
                let shouldHandleServiceEvent = await self.shouldHandleServiceEvent
                let onServiceEvent = await self.onServiceEvent
                await MainActor.run {
                    guard shouldHandleServiceEvent(source, tutorial) else { return }
                    sm?.handleServiceEvent(
                        source: source,
                        newState: state,
                        text: text,
                        autoDismiss: autoDismiss,
                        presentation: presentation
                    )
                    onServiceEvent(source, state, text, tutorial)
                }
            }
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(StateEventBus.socketPath)
    }
}
