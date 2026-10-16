import Foundation

struct ActivateProjectTool: MCPTool {
    let name = "activate_project"
    let description = """
        Focus or browse a Relay Runner project by absolute repo path or known alias. \
        Existing git repos get their local .orchestrator board config initialized if needed; \
        non-git folders are refused instead of running git init. Codex and Claude callers use \
        the same tool and may pass their provider label when known. A project with a running \
        session is focused; otherwise its board opens and no session starts. The current \
        session is never stopped. Pass continuation only when explicitly forwarding the \
        unfinished user request: after this turn finishes the app focuses the destination's \
        session, starting it if needed, and submits the request there once with its original \
        authority. Omit it for navigation. Use the general-tasks alias for the built-in project.
        """
    var notify: () -> Bool = { ConfirmationClient.notifyToolFiredAndWait(toolName: "activate_project") }
    var activate: (String, String?, String?) -> ProjectActivationOutcome = ConfirmationClient.requestProjectActivation

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "continuation": ["type": "string", "description": "Optional unfinished public user request to submit once to the destination project's session (started if needed) after this turn finishes. Explicit opt-in only; omit for navigation. Do not include private reasoning or unrelated history."],
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
    let description = "Compatibility alias for activate_project with Relay Runner's preinstalled general-tasks project in Application Support. A running general-tasks session is focused; otherwise its board opens and no session starts. The current session is never stopped. Pass continuation to forward an unfinished request once to the general-tasks session after this turn finishes, starting it if needed."
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

private func continuationText(_ arguments: [String: Any]) throws -> String? {
    guard let value = arguments["continuation"] else { return nil }
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf8.count <= 16_000,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 9 }) else {
        throw MCPToolError(message: "continuation must contain bounded public request text without terminal controls.")
    }
    return text
}
