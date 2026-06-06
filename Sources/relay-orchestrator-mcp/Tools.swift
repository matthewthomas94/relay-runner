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
        return try await proxy(method: "POST", path: "/v1/runs", body: body)
    }
}

// MARK: - list_runs

struct ListRunsTool: MCPTool {
    let name = "list_runs"
    let description = """
        List orchestrator runs, newest first. Pass `state` to filter by lifecycle state \
        (Claimed, Running, Succeeded, Failed, Stalled, Canceled). Default limit: 100.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "state": [
                    "type": "string",
                    "enum": ["Claimed", "Running", "Succeeded", "Failed", "Stalled", "Canceled"],
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
                        "blocked_work",
                        "awaiting_merge",
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
        Capture a meaningful work-session review directly into Graphify Core. Use this in place of the legacy \
        PM-sync copy/paste YAML workflow when the user wants to record shipped work, started work, blockers, \
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
