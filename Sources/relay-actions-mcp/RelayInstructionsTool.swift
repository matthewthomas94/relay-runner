import Foundation

// Claude Code truncates `initialize` instructions at 2048 characters, so
// `claude-code` clients get a compact summary and fetch the full rules here.
// Read-only; the server advertises it to `claude-code` clients only.
struct GetRelayInstructionsTool: MCPTool {
    let name = "get_relay_instructions"
    let description = """
        Return the full Relay stack screen-control rules (read-only). The initialize instructions are \
        a compact summary; read these before screen-control work you are unsure about.
        """

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        [["type": "text", "text": Instructions.payload]]
    }
}
