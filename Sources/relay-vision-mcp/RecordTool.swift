import Foundation

struct RecordTool: MCPTool {
    let name = "record"
    let description = """
        Record a connected display to an H.264 mp4 file and return the file's path (the video \
        itself is not returned inline). Defaults to the primary display, 4 seconds, 15 frames per \
        second; `duration_seconds` is capped at 30 and `fps` at 30. The frame size is the \
        display's native pixels scaled so the long edge is at most 2000 px. Use it to capture \
        animations and transitions that a single screenshot cannot show, then read or send the \
        file from the returned path.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "duration_seconds": [
                    "type": "number",
                    "description": "How long to record, in seconds. Default: 4. Minimum 0.5, maximum 30.",
                ],
                "fps": [
                    "type": "integer",
                    "description": "Frames per second written to the file. Default: 15. Maximum 30.",
                ],
                "display_index": [
                    "type": "integer",
                    "description": "Zero-based index into the list of connected displays. Default: 0 (primary).",
                ],
                "output_path": [
                    "type": "string",
                    "description": "Where to save the mp4. Default: a timestamped file in the temporary directory.",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        var forwarded = arguments
        forwarded["purpose"] = "record the screen"

        // Pulse ActionGlow as the recording starts, not only when it ends, so the user sees
        // observation is under way for the whole take.
        ConfirmationClient.notifyToolFired(toolName: name)

        let requested = (arguments["duration_seconds"] as? NSNumber)?.doubleValue ?? 4
        let timeout = Int(min(30, max(0, requested)).rounded(.up)) + 30

        switch ConfirmationClient.requestHostedTool(name: name, arguments: forwarded, timeoutSeconds: timeout) {
        case .succeeded(let content):
            return content
        case .failed(let message):
            throw MCPToolError(message: message)
        case .menuBarUnavailable:
            throw MCPToolError(message: """
                Relay Runner is not running or its app-side tool host is unavailable. Start Relay Runner, then retry the record tool.
                """)
        }
    }
}
