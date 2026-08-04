import Foundation

// Tool implementations — each wraps one HTTP call to the orchestrator daemon.

// MARK: - Helpers

private func requireString(_ args: [String: Any], _ key: String) throws -> String {
    guard let v = args[key] as? String, !v.isEmpty else {
        throw MCPToolError(message: "Missing or empty argument: \(key)")
    }
    return v
}

private func requireInt(_ args: [String: Any], _ key: String) throws -> Int {
    if let i = args[key] as? Int { return i }
    if let n = args[key] as? NSNumber { return n.intValue }
    if let s = args[key] as? String, let i = Int(s) { return i }
    throw MCPToolError(message: "Missing or invalid integer argument: \(key)")
}

private func optionalInt(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

private func claimedRelayCommand() -> (seq: Int, id: String, intentID: String?)? {
    let url = URL(fileURLWithPath: "/tmp/voice_cmd_claimed.json")
    guard FileManager.default.fileExists(atPath: "/tmp/voice_command_state.json"),
          let data = try? Data(contentsOf: url),
          let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let seq = optionalInt(raw["relay_command_seq"]),
          let id = raw["relay_command_id"] as? String,
          !id.isEmpty else {
        return nil
    }
    let intentID = (raw["intent_id"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (seq, id, intentID?.isEmpty == false ? intentID : nil)
}

private func proxy(method: String, path: String, body: [String: Any]? = nil) async throws -> [[String: Any]] {
    do {
        let payload = try await DaemonClient.request(method: method, path: path, body: body)
        return try toolTextContent(payload)
    } catch let e as DaemonError {
        throw e.asMCPToolError
    }
}

// MARK: - dispatch_ticket

struct DispatchTicketTool: MCPTool {
    let name = "dispatch_ticket"
    let description = """
        Dispatch a ticket from a repo's local kanban board to a sub-agent run. Implementation tickets use \
        an isolated `relay/<sanitized-id>` worktree and the review/merge lifecycle. Spike tickets use a \
        detached read-only snapshot, create no worker branch, and persist structured findings through a \
        daemon-owned ticket-only completion. Returns the run record (state, run_id, execution_mode, \
        workspace_path, branch).
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "ticket_id": [
                    "type": "string",
                    "description": "Ticket id matching the filename under .orchestrator/, e.g. 'RR-6'.",
                ],
                "repo_path": [
                    "type": "string",
                    "description": "Absolute path to the local git repo whose .orchestrator/ board owns the ticket. Required — the daemon won't infer the repo.",
                ],
                "context": [
                    "type": "string",
                    "description": "Optional caller-supplied context for the sub-agent. Sub-agents have no memory of the dispatching session — pass background that doesn't fit cleanly in the ticket body (recent decisions, related runs, constraints). Rendered into the worker's workflow prompt under 'Additional context from the dispatcher'.",
                ],
                "relay_command_seq": [
                    "type": "integer",
                    "description": "Optional Relay voice command sequence. When present, the daemon rejects dispatch if a newer voice command has superseded it.",
                ],
                "relay_command_id": [
                    "type": "string",
                    "description": "Optional Relay voice command id paired with relay_command_seq.",
                ],
                "relay_intent_id": [
                    "type": "string",
                    "description": "Optional stable Relay work-item id within the source voice turn.",
                ],
            ],
            "required": ["ticket_id", "repo_path"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "ticket_id": try requireString(arguments, "ticket_id"),
            "repo_path": try requireString(arguments, "repo_path"),
        ]
        if let ctx = arguments["context"] as? String, !ctx.isEmpty {
            body["context"] = ctx
        }
        if let seq = optionalInt(arguments["relay_command_seq"]),
           let id = arguments["relay_command_id"] as? String,
           !id.isEmpty {
            body["relay_command_seq"] = seq
            body["relay_command_id"] = id
            if let intentID = arguments["relay_intent_id"] as? String, !intentID.isEmpty {
                body["relay_intent_id"] = intentID
            }
        } else if let claimed = claimedRelayCommand() {
            body["relay_command_seq"] = claimed.seq
            body["relay_command_id"] = claimed.id
            if let intentID = claimed.intentID {
                body["relay_intent_id"] = intentID
            }
        }
        return try await proxy(method: "POST", path: "/v1/runs", body: body)
    }
}

// MARK: - list_runs

struct ListRunsTool: MCPTool {
    let name = "list_runs"
    let description = """
        List orchestrator runs, newest first. Pass `state` to filter by lifecycle state \
        (Claimed, Running, SpikeCompleted, AwaitingReview, Reviewing, MergeConflict, VerificationBlocked, Merged, Failed, Stalled, Canceled). Default limit: 100.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "state": [
                    "type": "string",
                    "enum": ["Claimed", "Running", "SpikeCompleted", "AwaitingReview", "Reviewing", "MergeConflict", "VerificationBlocked", "Merged", "Succeeded", "Failed", "Stalled", "Canceled"],
                ],
                "limit": ["type": "integer", "description": "Max rows to return. Default: 100."],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var query: [String] = []
        if let state = arguments["state"] as? String, !state.isEmpty {
            query.append("state=\(urlEscape(state))")
        }
        if let limit = arguments["limit"] as? Int {
            query.append("limit=\(limit)")
        }
        let path = "/v1/runs" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        return try await proxy(method: "GET", path: path)
    }
}

// MARK: - queue_drain_status

struct QueueDrainStatusTool: MCPTool {
    let name = "queue_drain_status"
    let description = """
        Inspect the durable rolling queue-drain goal for a repo. Optionally reconcile first, which runs the \
        bounded ready/review drain pass without spending provider model tokens. The payload shows observed \
        ticket IDs, provider goal mode/state, scheduled next actions, dependency waits, blockers, and completion state.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "repo_path": [
                    "type": "string",
                    "description": "Optional absolute path to the local git repo. When omitted, active drains across registered projects are returned.",
                ],
                "include_terminal": [
                    "type": "boolean",
                    "description": "Include completed or canceled drain records. Default: false.",
                ],
                "reconcile": [
                    "type": "boolean",
                    "description": "Run a bounded queue-drain reconciliation before reading status. Default: false.",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        if (arguments["reconcile"] as? Bool) == true {
            var body: [String: Any] = ["trigger": "mcp-queue-drain-status"]
            if let repoPath = arguments["repo_path"] as? String, !repoPath.isEmpty {
                body["repo_path"] = repoPath
            }
            _ = try await DaemonClient.request(method: "POST", path: "/v1/queue-drain/reconcile", body: body)
        }

        var query: [String] = []
        if let repoPath = arguments["repo_path"] as? String, !repoPath.isEmpty {
            query.append("repo_path=\(urlEscape(repoPath))")
        }
        if let includeTerminal = arguments["include_terminal"] as? Bool, includeTerminal {
            query.append("include_terminal=true")
        }
        let path = "/v1/queue-drains" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        return try await proxy(method: "GET", path: path)
    }
}

// MARK: - get_run

struct GetRunTool: MCPTool {
    let name = "get_run"
    let description = "Fetch a single orchestrator run by its numeric run_id. Includes state, exit code, log path, and the worktree path."

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
            ],
            "required": ["run_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        return try await proxy(method: "GET", path: "/v1/runs/\(id)")
    }
}

// MARK: - inspect_run_for_review

struct InspectRunForReviewTool: MCPTool {
    let name = "inspect_run_for_review"
    let description = """
        Inspect a completed worker run before accepting or retrying it. Returns the run record, worker log tail, \
        ticket run log from the worker branch, branch commits, diff stat, changed paths, and verification evidence. \
        Works for Codex and Claude runs because both providers write the same run database and worker log shape.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
            ],
            "required": ["run_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        return try await proxy(method: "GET", path: "/v1/runs/\(id)/review")
    }
}

// MARK: - review_run

struct ReviewRunTool: MCPTool {
    let name = "review_run"
    let description = """
        Dispatch a follow-up review/merge sub-agent for a completed worker run. The reviewer inspects the worker branch, \
        runs verification, then accepts or retries through the daemon so the foreground orchestrator does not directly \
        review or merge implementation branches. This path is provider-neutral for Codex and Claude runs.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
                "context": [
                    "type": "string",
                    "description": "Optional foreground context for the review/merge worker, such as verification expectations or known risk areas.",
                ],
            ],
            "required": ["run_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        var body: [String: Any] = [:]
        if let context = arguments["context"] as? String, !context.isEmpty {
            body["context"] = context
        }
        return try await proxy(method: "POST", path: "/v1/runs/\(id)/review", body: body)
    }
}

// MARK: - cancel_run

struct CancelRunTool: MCPTool {
    let name = "cancel_run"
    let description = """
        Cancel an in-flight run by run_id. Terminates the worker subprocess (SIGTERM, then SIGKILL after 5s) \
        and prunes the git worktree by default. Pass prune_worktree=false to keep the worktree for \
        post-mortem inspection.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
                "prune_worktree": [
                    "type": "boolean",
                    "description": "Remove the worktree after cancellation. Default: true.",
                ],
            ],
            "required": ["run_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        let prune = (arguments["prune_worktree"] as? Bool) ?? true
        return try await proxy(method: "POST", path: "/v1/runs/\(id)/cancel", body: ["prune_worktree": prune])
    }
}

// MARK: - reconcile_preserved_run

struct ReconcilePreservedRunTool: MCPTool {
    let name = "reconcile_preserved_run"
    let description = """
        Restore a missing terminal run-ledger row from a clean, committed canonical done or verification-blocked ticket. This recovery action does not edit the ticket, resume or dispatch work, or progress dependencies.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "repo_path": [
                    "type": "string",
                    "description": "Absolute path to the git repo containing the committed canonical ticket.",
                ],
                "ticket_id": [
                    "type": "string",
                    "description": "Canonical ticket id whose declared run_id should be restored.",
                ],
            ],
            "required": ["repo_path", "ticket_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let repoPath = try requireString(arguments, "repo_path")
        let ticketID = try requireString(arguments, "ticket_id")
        return try await proxy(
            method: "POST",
            path: "/v1/runs/reconcile-preserved",
            body: ["repo_path": repoPath, "ticket_id": ticketID]
        )
    }
}

// MARK: - resume_verification_blocked

struct ResumeVerificationBlockedTool: MCPTool {
    let name = "resume_verification_blocked"
    let description = """
        Explicitly resume a reviewed verification-blocked run after its external condition changes. The daemon commits the canonical ticket transition back to queued work, clears the old blocker fields, and dispatches a fresh attempt by default.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
                "reason": [
                    "type": "string",
                    "description": "What changed in the external environment, or why a deliberate retry is now appropriate.",
                ],
                "redispatch": [
                    "type": "boolean",
                    "description": "Dispatch a fresh worker attempt immediately. Default: true.",
                ],
            ],
            "required": ["run_id", "reason"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        let reason = try requireString(arguments, "reason")
        let redispatch = (arguments["redispatch"] as? Bool) ?? true
        return try await proxy(
            method: "POST",
            path: "/v1/runs/\(id)/resume-verification",
            body: ["reason": reason, "redispatch": redispatch]
        )
    }
}

// MARK: - spike follow-up tickets

struct ProposeSpikeFollowupsTool: MCPTool {
    let name = "propose_spike_followups"
    let description = """
        Build a durable, reviewable batch of implementation-ticket proposals from a completed spike report. \
        Omit proposals to derive drafts from the report's recommended next steps, or provide PM-refined drafts \
        with target project, acceptance criteria, dependencies, priority, and worker sizing. This never writes \
        tickets or dispatches workers; each proposal requires a separate accept decision.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "origin_repo_path": ["type": "string"],
                "origin_ticket_id": ["type": "string"],
                "origin_run_id": ["type": "integer"],
                "provider": ["type": "string", "description": "Optional foreground PM provider label."],
                "proposals": [
                    "type": "array",
                    "description": "Optional refined drafts. Omit to use the spike report recommendations.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "description": ["type": "string"],
                            "acceptance_criteria": ["type": "array", "items": ["type": "string"]],
                            "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low"]],
                            "depends_on": ["type": "array", "items": ["type": "string"]],
                            "worker_model": ["type": "string"],
                            "worker_effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh", "max"]],
                            "worker_sizing_rationale": ["type": "string"],
                            "worker_provider_notes": ["type": "string"],
                            "target_repo_path": ["type": "string"],
                        ],
                        "required": ["title", "description", "acceptance_criteria", "priority", "depends_on", "worker_model", "worker_effort", "worker_sizing_rationale", "worker_provider_notes"],
                    ],
                ],
            ],
            "required": ["origin_repo_path", "origin_ticket_id", "origin_run_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "origin_repo_path": try requireString(arguments, "origin_repo_path"),
            "origin_ticket_id": try requireString(arguments, "origin_ticket_id"),
            "origin_run_id": try requireInt(arguments, "origin_run_id"),
        ]
        if let provider = arguments["provider"] as? String, !provider.isEmpty {
            body["provider"] = provider
        }
        if let proposals = arguments["proposals"] as? [[String: Any]] {
            body["proposals"] = proposals
        }
        return try await proxy(method: "POST", path: "/v1/spikes/follow-ups/propose", body: body)
    }
}

struct ReviewSpikeFollowupTool: MCPTool {
    let name = "review_spike_followup"
    let description = """
        Edit, accept, or reject one proposed spike follow-up. Edit changes only the recoverable draft. Accept \
        atomically allocates and commits one backlog ticket on the selected canonical project board; it never \
        promotes or dispatches the ticket. Reject leaves other proposals untouched.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "batch_id": ["type": "string"],
                "proposal_id": ["type": "string"],
                "decision": ["type": "string", "enum": ["edit", "accept", "reject"]],
                "updates": [
                    "type": "object",
                    "description": "Fields to replace before edit or acceptance. Accepting with updates is atomic.",
                ],
                "relay_command_seq": ["type": "integer"],
                "relay_command_id": ["type": "string"],
                "relay_intent_id": ["type": "string"],
            ],
            "required": ["batch_id", "proposal_id", "decision"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let batchID = try requireString(arguments, "batch_id")
        let proposalID = try requireString(arguments, "proposal_id")
        var body: [String: Any] = ["decision": try requireString(arguments, "decision")]
        if let updates = arguments["updates"] as? [String: Any] {
            body["updates"] = updates
        }
        if let seq = optionalInt(arguments["relay_command_seq"]),
           let id = arguments["relay_command_id"] as? String,
           !id.isEmpty {
            body["relay_command_seq"] = seq
            body["relay_command_id"] = id
            if let intentID = arguments["relay_intent_id"] as? String, !intentID.isEmpty {
                body["relay_intent_id"] = intentID
            }
        } else if let claimed = claimedRelayCommand() {
            body["relay_command_seq"] = claimed.seq
            body["relay_command_id"] = claimed.id
            if let intentID = claimed.intentID {
                body["relay_intent_id"] = intentID
            }
        }
        return try await proxy(
            method: "POST",
            path: "/v1/spikes/follow-ups/\(urlEscape(batchID))/proposals/\(urlEscape(proposalID))/review",
            body: body
        )
    }
}

// MARK: - program_status

struct ProgramStatusTool: MCPTool {
    let name = "program_status"
    let description = """
        Query cross-project Program Manager status from Graphify Core. Use this for voice/text questions like \
        what all agents are doing, what is blocked across projects, what is awaiting merge, stale runs, \
        project summary, or what to look at next. Responses are concise and include project names, paths, \
        ticket IDs, and Codex/Claude provider labels when known.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "enum": [
                        "active_work",
                        "backlog_lane",
                        "ready_lane",
                        "in_progress_lane",
                        "done_lane",
                        "discovery_work",
                        "ready_work",
                        "blocked_work",
                        "awaiting_merge",
                        "done_work",
                        "stale_runs",
                        "summary",
                        "next",
                    ],
                    "description": "Program status view to return. Defaults to summary.",
                ],
                "provider": [
                    "type": "string",
                    "enum": ["codex", "claude"],
                    "description": "Optional provider filter. Codex and Claude use the same status schema.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum rows to include in the spoken summary. Default: 8.",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var query: [String] = []
        if let statusQuery = arguments["query"] as? String, !statusQuery.isEmpty {
            query.append("query=\(urlEscape(statusQuery))")
        }
        if let provider = arguments["provider"] as? String, !provider.isEmpty {
            query.append("provider=\(urlEscape(provider))")
        }
        if let limit = arguments["limit"] as? Int {
            query.append("limit=\(limit)")
        }

        let path = "/v1/program/status" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        let payload = try await DaemonClient.request(method: "GET", path: path)
        if let object = payload as? [String: Any], let message = object["message"] as? String {
            return [["type": "text", "text": message]]
        }
        return try toolTextContent(payload)
    }
}

// MARK: - session_capture

struct SessionCaptureTool: MCPTool {
    let name = "session_capture"
    let description = """
        Capture a meaningful work-session review directly into Graphify Core when the user wants to record shipped work, started work, blockers, \
        ideas, decisions, status updates, or notes. The tool writes ProgramEvent, Decision, Risk, Idea, and \
        Status nodes, then links them to project, ticket, and run nodes when repo_path, ticket_id, or run_id evidence is available. \
        Codex and Claude use the same schema; the daemon does not scrape either provider's transcript history, \
        so pass concise structured entries and any relevant conversation context explicitly.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "repo_path": [
                    "type": "string",
                    "description": "Absolute path to the repo/project being reviewed. Legacy .pm/project-id metadata is not required.",
                ],
                "entries": [
                    "type": "array",
                    "description": "Structured capture entries. Supported kind values include shipped, started, note, decision, blocker, risk, idea, and status.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": [
                                "type": "string",
                                "enum": ["shipped", "started", "note", "decision", "blocker", "risk", "idea", "status"],
                            ],
                            "title": ["type": "string"],
                            "summary": ["type": "string"],
                            "body": ["type": "string"],
                            "details": ["type": "string"],
                            "ticket_id": ["type": "string"],
                            "run_id": ["type": "integer"],
                            "status": ["type": "string"],
                        ],
                        "required": ["kind"],
                    ],
                ],
                "ticket_id": [
                    "type": "string",
                    "description": "Optional default ticket id to link entries to, e.g. RR-43.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "Optional default orchestrator run id to link entries to.",
                ],
                "provider": [
                    "type": "string",
                    "enum": ["codex", "claude"],
                    "description": "Optional provider label for the session being captured.",
                ],
                "context": [
                    "type": "string",
                    "description": "Optional concise caller-supplied conversation context. Needed when provider transcript history is not otherwise available.",
                ],
                "capture_id": [
                    "type": "string",
                    "description": "Optional idempotency key for this review capture.",
                ],
            ],
            "required": ["repo_path", "entries"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let entries = try requireEntries(arguments, "entries")
        var body: [String: Any] = [
            "repo_path": try requireString(arguments, "repo_path"),
            "entries": entries,
        ]
        for key in ["ticket_id", "provider", "context", "capture_id"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                body[key] = value
            }
        }
        if arguments["run_id"] != nil {
            body["run_id"] = try requireInt(arguments, "run_id")
        }

        let payload = try await DaemonClient.request(method: "POST", path: "/v1/program/capture", body: body)
        if let object = payload as? [String: Any], let message = object["message"] as? String {
            return [["type": "text", "text": message]]
        }
        return try toolTextContent(payload)
    }

    private func requireEntries(_ args: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let entries = args[key] as? [[String: Any]], !entries.isEmpty else {
            throw MCPToolError(message: "Missing or empty argument: \(key)")
        }
        return entries
    }
}

// MARK: - URL escaping

private func urlEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
}
