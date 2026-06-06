import Foundation

struct ActivateProjectTool: MCPTool {
    let name = "activate_project"
    let description = """
        Register and activate a Relay Runner project by absolute repo path or known alias. \
        Existing git repos get their local .orchestrator board config initialized if needed; \
        non-git folders are refused instead of running git init. Codex and Claude callers use \
        the same tool and may pass their provider label when known.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
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

        guard ConfirmationClient.notifyToolFiredAndWait(toolName: name) else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }

        switch ConfirmationClient.requestProjectActivation(project: project, provider: provider) {
        case .activated(let repoPath):
            return [["type": "text", "text": "Activated project at \(repoPath)."]]
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not acknowledge the project activation request.")
        }
    }
}
