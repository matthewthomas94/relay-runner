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

// MARK: - link_project

struct LinkProjectTool: MCPTool {
    let name = "link_project"
    let description = """
        Link a Linear project to a local git repo so the orchestrator knows where to dispatch its issues. \
        One-time setup per project. Pass the Linear project's ID (UUID), the absolute path to a local \
        clone of the repo, and the repo's remote URL. `default_branch` is the branch new worktrees \
        branch off of (default: 'main').
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "linear_project_id": ["type": "string", "description": "Linear project UUID."],
                "repo_path": ["type": "string", "description": "Absolute path to a local git clone."],
                "repo_remote": ["type": "string", "description": "Remote URL of the repo (e.g. git@github.com:owner/name.git)."],
                "default_branch": ["type": "string", "description": "Branch to create worktrees from. Default: main."],
            ],
            "required": ["linear_project_id", "repo_path", "repo_remote"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "linear_project_id": try requireString(arguments, "linear_project_id"),
            "repo_path": try requireString(arguments, "repo_path"),
            "repo_remote": try requireString(arguments, "repo_remote"),
            "default_branch": (arguments["default_branch"] as? String) ?? "main",
        ]
        return try await proxy(method: "POST", path: "/v1/projects", body: body)
    }
}

// MARK: - unlink_project

struct UnlinkProjectTool: MCPTool {
    let name = "unlink_project"
    let description = "Remove a Linear-project link. Does not touch the repo or any worktrees."

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "linear_project_id": ["type": "string"],
            ],
            "required": ["linear_project_id"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let id = try requireString(arguments, "linear_project_id")
        return try await proxy(method: "DELETE", path: "/v1/projects/\(urlEscape(id))")
    }
}

// MARK: - list_projects

struct ListProjectsTool: MCPTool {
    let name = "list_projects"
    let description = "List all linked Linear projects with their local repo paths and remotes."

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": []]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        return try await proxy(method: "GET", path: "/v1/projects")
    }
}

// MARK: - dispatch_issue

struct DispatchIssueTool: MCPTool {
    let name = "dispatch_issue"
    let description = """
        Dispatch a Linear issue to a sub-agent run. The orchestrator creates a git worktree for the \
        issue's branch (relay/<sanitized-id>), renders the workflow prompt, and spawns `claude -p` \
        in that worktree. The worker reads issue context via the Linear MCP and posts a status \
        comment back when done. Returns the run record (state, run_id, workspace_path, branch). \
        If a project_id isn't provided and only one project is linked, that project is assumed.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "identifier": [
                    "type": "string",
                    "description": "Linear issue identifier, e.g. 'REL-42'.",
                ],
                "linear_project_id": [
                    "type": "string",
                    "description": "Optional Linear project ID. Required only if multiple projects are linked.",
                ],
            ],
            "required": ["identifier"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "identifier": try requireString(arguments, "identifier"),
        ]
        if let pid = arguments["linear_project_id"] as? String, !pid.isEmpty {
            body["linear_project_id"] = pid
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

// MARK: - URL escaping

private func urlEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
}
