import Foundation

/// Listens on `/tmp/relay_actions.sock` for messages from the RelayActionsMCP
/// helper binary. Message types:
///
/// 1. `{"type":"tool_fired","tool":"<name>"}` — fire-and-forget notification
///    that any Relay Actions MCP tool just ran. Drives the perimeter glow:
///    transitions StateMachine to `.actionGlow(awaitingConfirmation: nil)`
///    and starts (or refreshes) a 10s decay timer. When `"reply": true` is
///    present, writes `{"result":"ok"}` before closing.
///
/// 2. `{"type":"propose","id":"<uuid>","summary":"...","risk":"medium|high"}` —
///    the MCP server is blocking inside `propose_action`. We update state to
///    `.actionGlow(awaitingConfirmation: prompt)`, hold the connection
///    open, and wait for `resolve(requestId:confirmed:)` to be called by
///    CapsLockGesture when the user double-taps. Then we write back
///    `{"id":"<uuid>","result":"confirmed"|"rejected"|"timeout"}` and close.
///
/// 3. `{"type":"toggle_board"}` — request/reply command that toggles the
///    local kanban board through `AppState.toggleBoard()`.
///
/// 4. `{"type":"activate_project","project":"<path-or-alias>","provider":"codex|claude"}`
///    — request/reply command that registers and activates a project through
///    the menu-bar app's project registry.
///
/// 5. `{"type":"project_scope_token","project":"<path-or-alias>","context_id":"<id>"}`
///    — RR-442 request/reply command that issues the general session a
///    confirmed scope token for one registered project.
///
/// 6. `{"type":"find_project","name":"<spoken name>","source":{...}}` — RR-443
///    read-only request/reply that matches a spoken name against the registry.
///
/// 7. `{"type":"register_project","kind":"existing|new","name":"<new name>","user_answer":"...","source":{...}}`
///    — RR-443 request/reply that registers a project the user named, through
///    the shared folder picker, only inside the user's current answering turn.
///
/// 8. `{"type":"perform_tool","tool":"click|type|key|scroll|screenshot","arguments":{...}}`
///    — request/reply command that runs permission-gated Relay Actions/Vision
///    work in the Relay Runner app process. MCP helpers stay protocol adapters
///    while the app owns Accessibility and Screen Recording attribution.
///
/// Stream socket (not datagram) so request/reply works on the same connection
/// without connection-id juggling. Per-connection accept loop runs as long as
/// the bus is started.
actor ActionsConfirmBus {

    static let socketPath = "/tmp/relay_actions.sock"
    private static let decaySeconds: UInt64 = 10
    private static let confirmationTimeoutSeconds: UInt64 = 30

    private var listenFd: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private weak var stateMachine: StateMachine?

    /// Called when PermissionPreflight reports a permission missing for a
    /// previously-onboarded parent — `AppState` wires this to reset the
    /// tracker and re-surface the wizard. Proactive wizard surfacing for
    /// not-yet-onboarded parents is driven by `AppState`'s bridge watchdog
    /// reading `currentParent()`, not by a bus callback — the bus has no
    /// signal that distinguishes "MCP just spawned because Claude opened"
    /// from "user actually started voice."
    private let onParentPermissionRevoked: ((String, String) async -> Void)?
    private let onToggleBoard: (() async -> Void)?
    private let onActivateProject: (@MainActor (String, String?, [String: String]?) async -> ProjectActivationReply)?
    private let onActivateGeneral: (@MainActor ([String: String]?) async -> GeneralActivationReply)?
    private let onProjectScopeToken: (@MainActor (String, String?) async -> ProjectScopeTokenReply)?
    private let onFindProject: (@MainActor (String, [String: String]?) async -> ProjectLookupReply)?
    private let onRegisterProject: (@MainActor (VoiceProjectRegistration.Request, String, [String: String]) async -> ProjectRegistrationReply)?
    private let onHostedToolPermissionMissing: ((PermissionKind, String) async -> Void)?

    /// Outstanding `propose_action` requests, keyed by request id. Value is
    /// the connection fd holding open the reply. When the user double-taps
    /// (or the timeout fires), we look up the fd, write the JSON reply, and
    /// close the connection.
    private var pending: [String: Int32] = [:]

    /// Most recent decay task — cancelled and replaced each time a new
    /// tool_fired or propose arrives, so the 10s window restarts on activity.
    private var decayTask: Task<Void, Never>?

    /// Per-request timeout tasks — fire after 30s if the user hasn't
    /// responded, write a "timeout" reply, and clear the pending entry.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Most recent parent reported by the MCP server's `parent_detected`
    /// message. Read by `AppState` via `currentParent()` when the voice
    /// bridge transitions alive — that's the moment "user is engaging
    /// Relay Runner from this app." The MCP startup itself isn't a usable
    /// signal because Claude.app and IDE-embedded Claude all spawn the
    /// MCP server on session boot regardless of voice.
    private var lastDetectedParent: String?

    init(stateMachine: StateMachine,
         onParentPermissionRevoked: ((String, String) async -> Void)? = nil,
         onToggleBoard: (() async -> Void)? = nil,
         onActivateProject: (@MainActor (String, String?, [String: String]?) async -> ProjectActivationReply)? = nil,
         onActivateGeneral: (@MainActor ([String: String]?) async -> GeneralActivationReply)? = nil,
         onProjectScopeToken: (@MainActor (String, String?) async -> ProjectScopeTokenReply)? = nil,
         onFindProject: (@MainActor (String, [String: String]?) async -> ProjectLookupReply)? = nil,
         onRegisterProject: (@MainActor (VoiceProjectRegistration.Request, String, [String: String]) async -> ProjectRegistrationReply)? = nil,
         onHostedToolPermissionMissing: ((PermissionKind, String) async -> Void)? = nil) {
        self.stateMachine = stateMachine
        self.onParentPermissionRevoked = onParentPermissionRevoked
        self.onToggleBoard = onToggleBoard
        self.onActivateProject = onActivateProject
        self.onActivateGeneral = onActivateGeneral
        self.onProjectScopeToken = onProjectScopeToken
        self.onFindProject = onFindProject
        self.onRegisterProject = onRegisterProject
        self.onHostedToolPermissionMissing = onHostedToolPermissionMissing
    }

    func start() {
        stop()

        unlink(ActionsConfirmBus.socketPath)

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            NSLog("[ActionsConfirmBus] socket() failed: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = ActionsConfirmBus.socketPath.utf8CString
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
            NSLog("[ActionsConfirmBus] bind() failed: \(errno)")
            close(sock)
            return
        }
        chmod(ActionsConfirmBus.socketPath, S_IRUSR | S_IWUSR)

        // Backlog of 8 — propose_action calls are inherently sequential per
        // claude session, but we may have a tool_fired in flight while a
        // propose is open. 8 leaves headroom for parallel sessions.
        guard listen(sock, 8) == 0 else {
            NSLog("[ActionsConfirmBus] listen() failed: \(errno)")
            close(sock)
            return
        }

        self.listenFd = sock
        NSLog("[ActionsConfirmBus] Listening on \(ActionsConfirmBus.socketPath)")

        acceptTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fd = await self.listenFd
                guard fd >= 0 else { return }

                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, 200)
                if pollResult <= 0 { continue }

                let conn = accept(fd, nil, nil)
                if conn < 0 { continue }

                // Hand off to a per-connection task so multiple connections
                // can be in flight (e.g. a tool_fired arriving while a
                // propose is open). The connection-handler closes its own fd.
                Task { [weak self] in
                    await self?.handleConnection(fd: conn)
                }
            }
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        decayTask?.cancel()
        decayTask = nil
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        // Reply "rejected" to anything still pending so the MCP server doesn't
        // hang forever after a relay-runner shutdown.
        for fd in pending.values {
            writeReply(fd: fd, requestId: "", result: "rejected")
            close(fd)
        }
        pending.removeAll()
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(ActionsConfirmBus.socketPath)
    }

    // MARK: - Connection handling

    func handleConnection(fd: Int32) async {
        // Read one JSON line, dispatch, then either close (tool_fired) or
        // hold open (propose) until resolve() is called.
        guard validatePeer(fd: fd) else {
            close(fd)
            return
        }
        guard let data = readLine(fd: fd) else {
            close(fd)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            close(fd)
            return
        }

        switch type {
        case "tool_fired":
            // Fire-and-forget. Update state, refresh decay, close connection.
            await enterActionGlow(prompt: nil)
            if (json["reply"] as? Bool) == true {
                writeReply(fd: fd, requestId: "", result: "ok")
            }
            close(fd)

        case "parent_detected":
            // Cache only — UI is surfaced by AppState when /relay-bridge
            // (or menu-bar Start Session) actually starts the voice loop
            // from this parent. The MCP server fires this on every startup
            // (Claude.app, terminal, IDE all auto-spawn it on session boot),
            // which isn't a sign of user intent on its own.
            if let parent = json["parent"] as? String {
                lastDetectedParent = parent
            }
            close(fd)

        case "parent_permission_revoked":
            // PermissionPreflight saw a still-missing permission for an already-
            // onboarded parent. Reset onboarded state and re-surface the wizard
            // so the user knows what to fix.
            if let parent = json["parent"] as? String {
                let permission = json["permission"] as? String ?? "unknown"
                await onParentPermissionRevoked?(parent, permission)
            }
            close(fd)

        case "toggle_board":
            await onToggleBoard?()
            writeReply(fd: fd, requestId: "", result: "ok")
            close(fd)

        case "activate_project" where json["continuation"] != nil && !(json["continuation"] is [String: String]):
            writePayload(fd: fd, payload: ["result": "error", "message": "Invalid continuation identity."])
            close(fd)

        case "activate_general" where json["continuation"] != nil && !(json["continuation"] is [String: String]):
            writePayload(fd: fd, payload: ["result": "error", "message": "Invalid continuation identity."])
            close(fd)

        case "activate_project":
            guard let project = json["project"] as? String else {
                writePayload(fd: fd, payload: [
                    "result": "error",
                    "message": "activate_project requires a project path or alias.",
                ])
                close(fd)
                return
            }
            let provider = json["provider"] as? String
            let reply = await onActivateProject?(project, provider, json["continuation"] as? [String: String]) ?? .failed(
                message: "Relay Runner cannot activate projects right now."
            )
            switch reply {
            case .activated(let repoPath, let message):
                var payload: [String: Any] = ["result": "ok", "repo_path": repoPath]
                if let message { payload["message"] = message }
                writePayload(fd: fd, payload: payload)
            case .queued(let repoPath, let message):
                writePayload(fd: fd, payload: ["result": "ok", "repo_path": repoPath, "pending": true, "message": message])
            case .failed(let message):
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "activate_general":
            let reply = await onActivateGeneral?(json["continuation"] as? [String: String]) ?? .failed(message: "Relay Runner cannot select General right now.")
            switch reply {
            case .selected(let message):
                writePayload(fd: fd, payload: ["result": "ok", "message": message])
            case .failed(let message):
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "project_scope_token":
            guard let project = json["project"] as? String,
                  !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                writePayload(fd: fd, payload: ["result": "error", "message": "project_scope_token requires a project path or alias."])
                close(fd)
                return
            }
            let reply = await onProjectScopeToken?(project, json["context_id"] as? String)
                ?? .failed(message: "Relay Runner cannot issue project scope tokens right now.")
            switch reply {
            case .issued(let token, let displayName):
                var payload: [String: Any] = [
                    "result": "ok",
                    "project_id": token.projectID,
                    "display_name": displayName,
                    "repo_path": token.repositoryPath,
                ]
                if let encoded = token.encodedValue {
                    payload["project_scope_token"] = encoded
                    writePayload(fd: fd, payload: payload)
                } else {
                    writePayload(fd: fd, payload: ["result": "error", "message": "The project scope token could not be encoded."])
                }
            case .failed(let message):
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "find_project":
            guard let name = json["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  json["source"] == nil || json["source"] is [String: String] else {
                writePayload(fd: fd, payload: ["result": "error", "message": "find_project requires a spoken project name."])
                close(fd)
                return
            }
            let reply = await onFindProject?(name, json["source"] as? [String: String])
                ?? .failed(message: "Relay Runner cannot read the project registry right now.")
            switch reply {
            case .found(let result):
                writePayload(fd: fd, payload: ["result": "ok", "match": Self.lookupPayload(result)])
            case .failed(let message):
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "register_project":
            let request: VoiceProjectRegistration.Request
            do {
                request = try VoiceProjectRegistration.request(
                    kind: json["kind"] as? String, name: json["name"] as? String,
                    userAnswer: json["user_answer"] as? String
                )
            } catch {
                writePayload(fd: fd, payload: ["result": "error", "message": String(describing: error)])
                close(fd)
                return
            }
            guard let source = json["source"] as? [String: String],
                  let answer = json["user_answer"] as? String else {
                writePayload(fd: fd, payload: ["result": "error", "message": "register_project requires an app-managed native user turn."])
                close(fd)
                return
            }
            let reply = await onRegisterProject?(request, answer, source)
                ?? .failed(message: "Relay Runner cannot register projects right now.")
            switch reply {
            case .registered(let project, let token):
                var payload: [String: Any] = [
                    "result": "ok",
                    "kind": request.kind.rawValue,
                    "project_id": project.projectID,
                    "display_name": project.displayName,
                    "repo_path": project.lastResolvedPath,
                ]
                if let encoded = token?.encodedValue { payload["project_scope_token"] = encoded }
                writePayload(fd: fd, payload: payload)
            case .cancelled(let message):
                writePayload(fd: fd, payload: ["result": "cancelled", "message": message])
            case .failed(let message):
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "perform_tool":
            guard let tool = json["tool"] as? String else {
                writePayload(fd: fd, payload: [
                    "result": "error",
                    "message": "perform_tool requires a tool name.",
                ])
                close(fd)
                return
            }
            let arguments = json["arguments"] as? [String: Any] ?? [:]
            switch await RelayHostedTool.perform(tool: tool, arguments: arguments) {
            case .success(let content):
                writePayload(fd: fd, payload: ["result": "ok", "content": content])
            case .failure(let message):
                if let permission = RelayHostedTool.requiredPermission(for: tool),
                   RelayHostedTool.isMissingPermissionFailure(message, for: permission) {
                    await onHostedToolPermissionMissing?(permission, arguments["purpose"] as? String ?? "")
                }
                writePayload(fd: fd, payload: ["result": "error", "message": message])
            }
            close(fd)

        case "propose":
            guard let id = json["id"] as? String,
                  let summary = json["summary"] as? String,
                  let risk = json["risk"] as? String else {
                close(fd)
                return
            }
            let prompt = ConfirmationPrompt(summary: summary, risk: risk, requestId: id)
            await enterActionGlow(prompt: prompt)
            pending[id] = fd
            // 30s timeout — if no double-tap arrives, reply "timeout" and
            // close. The user may have walked away or never noticed the prompt.
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: ActionsConfirmBus.confirmationTimeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.resolve(requestId: id, result: "timeout")
            }
            // Do NOT close — the reply happens later from resolve().

        default:
            close(fd)
        }
    }

    private func readLine(fd: Int32) -> Data? {
        // Read up to 8KB or until newline. propose_action summaries are
        // user-readable strings, so this cap is generous.
        var buffer = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while total < buffer.count {
            let n = recv(fd, &buffer[total], buffer.count - total, 0)
            if n <= 0 { break }
            total += n
            if buffer[..<total].contains(0x0A) {
                if let nl = buffer[..<total].firstIndex(of: 0x0A) {
                    return Data(buffer[..<nl])
                }
            }
        }
        return total > 0 ? Data(buffer[..<total]) : nil
    }

    // MARK: - State + decay

    private func enterActionGlow(prompt: ConfirmationPrompt?) async {
        let sm = stateMachine
        await MainActor.run {
            sm?.setActionGlow(awaitingConfirmation: prompt)
        }
        touchDecay()
    }

    /// Most recent parent reported by the MCP server, or nil if no MCP server
    /// has connected this session yet. AppState reads this when the voice
    /// bridge transitions alive so the per-parent wizard is tied to the
    /// "user just activated voice from this app" moment rather than the
    /// "MCP server happened to spawn" moment.
    func currentParent() -> String? {
        lastDetectedParent
    }

    private func touchDecay() {
        decayTask?.cancel()
        decayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ActionsConfirmBus.decaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.expireDecay()
        }
    }

    private func expireDecay() async {
        // Don't expire while a confirmation is still pending — the user
        // may take a moment to decide. Decay restarts only when the prompt
        // is resolved.
        if !pending.isEmpty { return }
        let sm = stateMachine
        await MainActor.run {
            sm?.clearActionGlow()
        }
    }

    // MARK: - Resolution (called by CapsLockGesture)

    /// Bridge entry point — non-actor caller (CapsLockGesture on main thread)
    /// resolves the most recently pending prompt with the given verdict.
    /// Returns whether anything was resolved (so the gesture can decide
    /// whether to fall through to the play/cancel default behavior).
    func resolveLatest(confirmed: Bool) async -> Bool {
        // Most recent pending = the prompt the user is looking at right now.
        // dictionary insertion order isn't preserved in Swift's Dictionary,
        // so we ask the StateMachine which prompt is currently surfaced.
        let sm = stateMachine
        let promptId: String? = await MainActor.run {
            sm?.pendingConfirmation?.requestId
        }
        guard let id = promptId, pending[id] != nil else { return false }
        await resolve(requestId: id, result: confirmed ? "confirmed" : "rejected")
        return true
    }

    private func resolve(requestId: String, result: String) async {
        guard let fd = pending.removeValue(forKey: requestId) else { return }
        timeoutTasks.removeValue(forKey: requestId)?.cancel()
        writeReply(fd: fd, requestId: requestId, result: result)
        close(fd)

        // Clear the prompt from the state machine. If there's another pending
        // prompt (rare — multi-session), surface it; otherwise drop into
        // post-resolution relay-vision idle and let the decay timer
        // eventually clear the perimeter glow.
        let nextPromptId = pending.keys.first
        let sm = stateMachine
        await MainActor.run {
            sm?.setActionGlow(awaitingConfirmation: nil)
            // If there's a queued prompt, the next propose-handler will set
            // it. We don't reach into stored prompt data here because the
            // bus doesn't keep ConfirmationPrompt structs around — they're
            // serialised into the StateMachine at receive time. Multi-prompt
            // queueing is a Slice 3.1 problem; v1 expects one outstanding.
            _ = nextPromptId
        }
        touchDecay()
    }

    private func writeReply(fd: Int32, requestId: String, result: String) {
        let payload: [String: Any] = ["id": requestId, "result": result]
        writePayload(fd: fd, payload: payload)
    }

    private func writePayload(fd: Int32, payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func validatePeer(fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else {
            NSLog("[ActionsConfirmBus] getpeereid() failed: \(errno)")
            return false
        }
        guard uid == getuid() else {
            NSLog("[ActionsConfirmBus] rejected peer uid \(uid); expected \(getuid())")
            return false
        }
        _ = gid
        return true
    }
}

enum ProjectActivationReply {
    case activated(repoPath: String, message: String? = nil)
    case queued(repoPath: String, message: String)
    case failed(message: String)
}

enum GeneralActivationReply {
    case selected(message: String)
    case failed(message: String)
}

enum ProjectScopeTokenReply {
    case issued(ConfirmedProjectScopeToken, displayName: String)
    case failed(message: String)
}

enum ProjectLookupReply {
    case found(ProjectNameMatcher.Result)
    case failed(message: String)
}

enum ProjectRegistrationReply {
    case registered(RegisteredProjectV2, token: ConfirmedProjectScopeToken?)
    case cancelled(message: String)
    case failed(message: String)
}

extension ActionsConfirmBus {
    /// The `find_project` reply body. Paths and names only; nothing private
    /// beyond what the registry already shows in the Projects list.
    static func lookupPayload(_ result: ProjectNameMatcher.Result) -> [String: Any] {
        [
            "status": result.status.rawValue,
            "matches": result.matches.map { match -> [String: Any] in
                [
                    "project_id": match.candidate.projectID,
                    "display_name": match.candidate.displayName,
                    "folder_name": URL(fileURLWithPath: match.candidate.repoPath).lastPathComponent,
                    "repo_path": match.candidate.repoPath,
                    "match": match.tier.rawValue,
                    "score": (match.score * 100).rounded() / 100,
                ]
            },
        ]
    }
}
