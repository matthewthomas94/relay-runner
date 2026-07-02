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

private func claimedRelayCommand() -> (seq: Int, id: String)? {
    let url = URL(fileURLWithPath: "/tmp/voice_cmd_claimed.json")
    guard FileManager.default.fileExists(atPath: "/tmp/voice_command_state.json"),
          let data = try? Data(contentsOf: url),
          let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let seq = optionalInt(raw["relay_command_seq"]),
          let id = raw["relay_command_id"] as? String,
          !id.isEmpty else {
        return nil
    }
    return (seq, id)
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
        Dispatch a ticket from a repo's local kanban board to a sub-agent run. The orchestrator creates \
        a git worktree at branch `relay/<sanitized-id>`, renders the workflow prompt, and spawns \
        the configured agent in that worktree. The worker reads the ticket from `<repo_path>/.orchestrator/<ticket_id>.md`, \
        updates its YAML status, appends a run log to the body, and commits everything. Returns the run \
        record (state, run_id, workspace_path, branch).
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
        } else if let claimed = claimedRelayCommand() {
            body["relay_command_seq"] = claimed.seq
            body["relay_command_id"] = claimed.id
        }
        return try await proxy(method: "POST", path: "/v1/runs", body: body)
    }
}

// MARK: - list_runs

struct ListRunsTool: MCPTool {
    let name = "list_runs"
    let description = """
        List orchestrator runs, newest first. Pass `state` to filter by lifecycle state \
        (Claimed, Running, AwaitingReview, MergeConflict, Merged, Failed, Stalled, Canceled). Default limit: 100.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "state": [
                    "type": "string",
                    "enum": ["Claimed", "Running", "AwaitingReview", "MergeConflict", "Merged", "Succeeded", "Failed", "Stalled", "Canceled"],
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
        Accept or retry a worker run that is awaiting orchestrator review. `decision=accept` merges the worker branch \
        into the source repo, prunes the worktree and branch, publishes the ticket's done state through that merge, \
        and then progresses dependents. `decision=retry` marks the reviewed run failed, prunes its worktree and branch, \
        and optionally dispatches a fresh attempt. This path is provider-neutral for Codex and Claude runs.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "run_id": ["type": "integer"],
                "decision": [
                    "type": "string",
                    "enum": ["accept", "retry"],
                ],
                "reason": [
                    "type": "string",
                    "description": "Required human/orchestrator rationale when retrying; ignored for accept.",
                ],
                "redispatch": [
                    "type": "boolean",
                    "description": "For decision=retry, dispatch a fresh attempt after pruning. Default: true.",
                ],
            ],
            "required": ["run_id", "decision"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireInt(arguments, "run_id")
        var body: [String: Any] = [
            "decision": try requireString(arguments, "decision"),
        ]
        if let reason = arguments["reason"] as? String, !reason.isEmpty {
            body["reason"] = reason
        }
        if let redispatch = arguments["redispatch"] as? Bool {
            body["redispatch"] = redispatch
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
