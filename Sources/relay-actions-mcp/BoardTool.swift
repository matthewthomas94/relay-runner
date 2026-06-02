import Foundation

struct ToggleBoardTool: MCPTool {
    let name = "toggle_board"
    let description = """
        Toggle Relay Runner's local kanban board overlay. Use when the user asks to \
        bring up, show, hide, or dismiss the board. Requires the Relay Runner menu-bar \
        app to be running; if no /relay-bridge session is active, Relay Runner shows \
        the standard "No session running" prompt.
        """

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "required": []]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard ConfirmationClient.notifyToolFiredAndWait(toolName: name) else {
            throw MCPToolError(message: "Relay Runner menu-bar app is not running or /tmp/relay_actions.sock is unavailable.")
        }

        switch ConfirmationClient.requestBoardToggle() {
        case .delivered:
            return [["type": "text", "text": "Board toggle requested."]]
        case .menuBarUnavailable:
            throw MCPToolError(message: "Relay Runner menu-bar app did not acknowledge the board toggle request.")
        }
    }
}
