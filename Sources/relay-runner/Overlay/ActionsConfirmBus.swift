import Foundation

/// Listens on `/tmp/relay_actions.sock` for messages from the RelayActionsMCP
/// helper binary. Two kinds:
///
/// 1. `{"type":"tool_fired","tool":"<name>"}` — fire-and-forget notification
///    that any computer-action MCP tool just ran. Drives the perimeter glow:
///    transitions StateMachine to `.computerVision(awaitingConfirmation: nil)`
///    and starts (or refreshes) a 10s decay timer.
///
/// 2. `{"type":"propose","id":"<uuid>","summary":"...","risk":"medium|high"}` —
///    the MCP server is blocking inside `propose_action`. We update state to
///    `.computerVision(awaitingConfirmation: prompt)`, hold the connection
///    open, and wait for `resolve(requestId:confirmed:)` to be called by
///    CapsLockGesture when the user double-taps. Then we write back
///    `{"id":"<uuid>","result":"confirmed"|"rejected"|"timeout"}` and close.
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

    /// Optional callbacks for the per-parent permissions wizard. Called from
    /// the actor when the MCP server reports a new parent terminal/IDE
    /// or signals a previously-onboarded parent has lost a permission.
    /// `AppState` wires these to `ParentOnboardingController` on main.
    private let onParentDetected: ((String) async -> Void)?
    private let onParentPermissionRevoked: ((String, String) async -> Void)?

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
    /// message. Cached so we can attach it to the first real tool use without
    /// re-asking the MCP server. The wizard does NOT surface on
    /// `parent_detected` itself — Claude.app and other Claude clients spawn
    /// the MCP server on session boot just by being opened, which would pop
    /// the wizard for users who never intend to use computer-action tools.
    /// Defer the trigger to actual tool use instead.
    private var lastDetectedParent: String?

    init(stateMachine: StateMachine,
         onParentDetected: ((String) async -> Void)? = nil,
         onParentPermissionRevoked: ((String, String) async -> Void)? = nil) {
        self.stateMachine = stateMachine
        self.onParentDetected = onParentDetected
        self.onParentPermissionRevoked = onParentPermissionRevoked
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

    private func handleConnection(fd: Int32) async {
        // Read one JSON line, dispatch, then either close (tool_fired) or
        // hold open (propose) until resolve() is called.
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
            await enterComputerVision(prompt: nil)
            // First real tool use is when "the user is engaging Relay Runner"
            // — that's when the wizard is relevant. AppState's closure dedupes
            // via ParentOnboardingTracker, so calling on every tool_fired is
            // cheap and self-throttling.
            await maybeSurfaceParentWizard()
            close(fd)

        case "parent_detected":
            // Cache only — do NOT surface the wizard yet. Claude.app and other
            // MCP-aware Claude clients spawn the relay-actions-mcp server on
            // session boot, so this message arrives the moment Claude starts —
            // long before the user has indicated any interest in voice-driven
            // computer actions. Wait until they actually fire a tool.
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

        case "propose":
            guard let id = json["id"] as? String,
                  let summary = json["summary"] as? String,
                  let risk = json["risk"] as? String else {
                close(fd)
                return
            }
            let prompt = ConfirmationPrompt(summary: summary, risk: risk, requestId: id)
            await enterComputerVision(prompt: prompt)
            // propose for medium/high never goes through the tool_fired path
            // (the server suppresses the standard notify), so surface the
            // wizard here too. Pre-confirmation is also a defensible moment —
            // the user is about to be asked to confirm a click, and giving
            // them the wizard at the same time means the perimeter pulse and
            // the wizard appear together rather than the wizard popping
            // afterwards.
            await maybeSurfaceParentWizard()
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

    private func enterComputerVision(prompt: ConfirmationPrompt?) async {
        let sm = stateMachine
        await MainActor.run {
            sm?.setComputerVision(awaitingConfirmation: prompt)
        }
        touchDecay()
    }

    /// Hand the cached parent off to AppState's wizard closure, which checks
    /// `ParentOnboardingTracker` and shows the window only on first sight.
    /// Safe to call on every tool firing — the closure self-throttles via
    /// the tracker, and an "unknown" parent (no terminal pattern matched in
    /// the process chain) is filtered out by the closure.
    private func maybeSurfaceParentWizard() async {
        guard let parent = lastDetectedParent else { return }
        await onParentDetected?(parent)
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
            sm?.clearComputerVision()
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
        // post-resolution computer-vision idle and let the decay timer
        // eventually clear the perimeter glow.
        let nextPromptId = pending.keys.first
        let sm = stateMachine
        await MainActor.run {
            sm?.setComputerVision(awaitingConfirmation: nil)
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
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        data.append(0x0A)
        _ = data.withUnsafeBytes { ptr -> Int in
            send(fd, ptr.baseAddress, data.count, 0)
        }
    }
}
