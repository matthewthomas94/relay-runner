import Foundation

struct ActivateProjectTool: MCPTool {
    let name = "activate_project"
    let description = """
        Browse a Relay Runner project's board by absolute repo path or known alias. \
        Existing git repos get their local .orchestrator board config initialized if needed; \
        non-git folders are refused instead of running git init. Codex and Claude callers use \
        the same tool and may pass their provider label when known. Only the board changes: \
        no session is started, focused or switched. The current session is never stopped. It \
        already reaches every registered project, so continue unfinished work in it; \
        continuation is not forwarded. Use the general-tasks alias for the built-in project.
        """
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "activate_project") }
    var activate: (String, String?, String?) -> ProjectActivationOutcome = ConfirmationClient.requestProjectActivation

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "continuation": ["type": "string", "description": "Accepted for compatibility and not forwarded: the current session reaches every registered project, so continue the request there. Omit it."],
                "project": [
                    "type": "string",
                    "description": "Absolute repo path or registered project alias.",
                ],
                "provider": [
                    "type": "string",
                    "enum": ["codex", "claude"],
                    "description": "Optional provider label for activation metadata.",
                ],
            ],
            "required": ["project"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let project = arguments["project"] as? String,
              !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError(message: "activate_project requires a non-empty project path or alias.")
        }
        let provider = arguments["provider"] as? String

        guard notify() else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }

        switch activate(project, provider, try continuationText(arguments)) {
        case .activated(let repoPath, let message):
            return [["type": "text", "text": message ?? "Selected project at \(repoPath)."]]
        case .queued(_, let message):
            return [["type": "text", "text": message]]
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not acknowledge the project activation request.")
        }
    }
}

struct ActivateGeneralTool: MCPTool {
    let name = "activate_general"
    let description = "Compatibility alias for activate_project with Relay Runner's preinstalled general-tasks project in Application Support. Its board opens; no session is started, focused or switched. The current session is never stopped. Pass continuation to forward an unfinished request once to the general-tasks session after this turn finishes, starting it if needed."
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "activate_general") }
    var activate: (String?) -> GeneralActivationOutcome = ConfirmationClient.requestGeneralActivation

    var inputSchema: [String: Any] {
        ["type": "object", "properties": ["continuation": ["type": "string", "description": "Optional unfinished public user request to submit once to the general-tasks session (started if needed) after this turn finishes. Omit for navigation."]], "additionalProperties": false]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard Set(arguments.keys).isSubset(of: ["continuation"]) else { throw MCPToolError(message: "activate_general accepts only optional continuation text.") }
        guard notify() else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }
        switch activate(try continuationText(arguments)) {
        case .selected(let message): return [["type": "text", "text": message]]
        case .failed(let message): throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not acknowledge the General context request.")
        }
    }
}

/// RR-442: the general session's way to a scope token for a project
/// registered after it launched. The app refuses other sessions and any
/// reference outside the project registry.
struct ProjectScopeTokenTool: MCPTool {
    let name = "project_scope_token"
    let description = """
        Return a confirmed project scope token for one registered Relay Runner project, for the \
        general session only. Pass the registered repo path, project ID or name the user named. \
        Refused for paths outside the project registry and for project sessions. Use the token as \
        project_scope_token for that repo_path with dispatch_ticket, session_capture or the \
        daemon ticket writer. Needed only for a project registered after the session started; \
        RELAY_PROJECT_SCOPE_TOKENS already holds the others. Codex and Claude use the same tool.
        """
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "project_scope_token") }
    var request: (String) -> ProjectScopeTokenOutcome = { ConfirmationClient.requestProjectScopeToken(project: $0) }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "project": [
                    "type": "string",
                    "description": "Registered repo path, project ID, or project name.",
                ],
            ],
            "required": ["project"],
            "additionalProperties": false,
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let project = arguments["project"] as? String,
              !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError(message: "project_scope_token requires a non-empty registered project path or name.")
        }
        guard notify() else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }
        switch request(project) {
        case .issued(let projectID, let displayName, let repoPath, let token):
            let result: [String: String] = [
                "project_id": projectID,
                "display_name": displayName,
                "repo_path": repoPath,
                "project_scope_token": token,
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            return [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not answer the project scope token request.")
        }
    }
}

/// RR-443: read-only match of a spoken project name against the registry.
struct FindProjectTool: MCPTool {
    let name = "find_project"
    let description = """
        Match a project name the user said against the Relay Runner project registry. Read-only:         it never registers, opens, or changes anything. Case, spaces and punctuation are ignored,         so "relay runner" finds relay-runner. Returns status exact (display name), folder (folder         name), fuzzy (one close name to confirm), ambiguous (name the candidates and ask which) or         none (ask one question: an existing folder to add or a new project to create), with the         matching projects' IDs, names, folder names and paths. Codex and Claude use the same tool.
        """
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "find_project") }
    var lookup: (String) -> ProjectAppReplyOutcome = { ConfirmationClient.requestProjectLookup(name: $0) }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "The project name or path as the user said it."],
            ],
            "required": ["name"],
            "additionalProperties": false,
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let name = arguments["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1_000 else {
            throw MCPToolError(message: "find_project requires the spoken project name.")
        }
        guard notify() else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }
        switch lookup(name) {
        case .ok(let body):
            return [["type": "text", "text": try jsonText(body["match"] ?? [:])]]
        case .cancelled(let message), .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not answer the project lookup.")
        }
    }
}

/// RR-443: register a project the user named, once they answered whether it
/// is an existing folder or a new project. The app opens its shared folder
/// picker; the user chooses every location.
struct RegisterProjectTool: MCPTool {
    let name = "register_project"
    let description = """
        Add a project to the Relay Runner registry after find_project found none and the user         answered, in their current turn, whether it is an existing folder or a new project. Never         call it in the turn that asks. kind=existing opens the folder picker and registers the         chosen folder exactly as Add existing project does. kind=new needs the name the user gave;         the picker asks for the parent folder and the project is created and registered exactly as         Create new project does. There is no default location. Pass the user's answer as         user_answer. The general session gets the new project's project_scope_token. Codex and         Claude use the same tool; it needs a Relay Runner-managed session.
        """
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "register_project") }
    var register: (String, String?, String) -> ProjectAppReplyOutcome = {
        ConfirmationClient.requestProjectRegistration(kind: $0, name: $1, userAnswer: $2)
    }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["existing", "new"],
                    "description": "existing: add a folder that already exists. new: create a new project folder.",
                ],
                "name": ["type": "string", "description": "kind=new only: the project name the user gave, used as the new folder name."],
                "user_answer": ["type": "string", "description": "The user's own words from the current turn answering existing or new."],
            ],
            "required": ["kind", "user_answer"],
            "additionalProperties": false,
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let kind = arguments["kind"] as? String, ["existing", "new"].contains(kind) else {
            throw MCPToolError(message: "register_project requires kind existing or new.")
        }
        guard let answer = arguments["user_answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 4_000 else {
            throw MCPToolError(message: "register_project needs the user's answer from the current turn. Ask whether it is an existing folder or a new project, end your turn, and call it once they answer.")
        }
        let projectName = arguments["name"] as? String
        guard arguments["name"] == nil || projectName != nil else {
            throw MCPToolError(message: "name must be a string.")
        }
        guard notify() else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }
        switch register(kind, projectName, answer) {
        case .ok(let body):
            return [["type": "text", "text": try jsonText(body)]]
        case .cancelled(let message):
            return [["type": "text", "text": message]]
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not answer the project registration request.")
        }
    }
}

private func jsonText(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

private func continuationText(_ arguments: [String: Any]) throws -> String? {
    guard let value = arguments["continuation"] else { return nil }
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf8.count <= 16_000,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 9 }) else {
        throw MCPToolError(message: "continuation must contain bounded public request text without terminal controls.")
    }
    return text
}
