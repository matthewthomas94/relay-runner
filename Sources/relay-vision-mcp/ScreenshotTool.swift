import Foundation

struct ScreenshotTool: MCPTool {
    let name = "screenshot"
    let description = """
        Capture a screenshot of a connected display and return it as a base64-encoded PNG. \
        Defaults to the primary display. The returned image's pixel dimensions match \
        NSScreen.frame × backingScaleFactor (i.e. the display's native pixels). Coordinates \
        consumed by `click`, `scroll`, etc. are in this same pixel space — the agent can read \
        a coordinate directly off the image and pass it through.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "display_index": [
                    "type": "integer",
                    "description": "Zero-based index into the list of connected displays. Default: 0 (primary).",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var forwarded = arguments
        forwarded["purpose"] = "take a screenshot"

        switch ConfirmationClient.requestHostedTool(name: name, arguments: forwarded) {
        case .succeeded(let content):
            return content
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: """
                Relay Runner is not running or its app-side tool host is unavailable. Start Relay Runner, then retry the screenshot tool.
                """)
        }
    }
}
