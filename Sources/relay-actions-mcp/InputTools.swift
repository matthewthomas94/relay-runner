import Foundation

// Relay Actions input tools.
//
// The MCP helper remains the provider-facing protocol adapter for Codex and
// Claude. Permission-gated CGEvent posting is hosted by the running Relay
// Runner app process over /tmp/relay_actions.sock so Accessibility attribution
// belongs to Relay Runner, not the agent host.

// MARK: - Click

struct ClickTool: MCPTool {
    let name = "click"
    let description = """
        Post a mouse click at the given pixel coordinates. x/y are in the SAME pixel \
        space as the most recent `screenshot` tool output — read the coordinate directly \
        off the screenshot image and pass it through. `button` defaults to 'left'. \
        `modifiers` is an optional array of any of: 'cmd', 'shift', 'option', 'control'. \
        Call `propose_action` first for any state-changing click so the user can confirm \
        the action accurately.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x": ["type": "integer", "description": "Pixel X coordinate."],
                "y": ["type": "integer", "description": "Pixel Y coordinate."],
                "button": [
                    "type": "string",
                    "enum": ["left", "right", "middle"],
                    "description": "Mouse button to click. Default: left.",
                ],
                "double": [
                    "type": "boolean",
                    "description": "If true, post a double-click. Default: false.",
                ],
                "modifiers": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["cmd", "shift", "option", "control"]],
                    "description": "Modifier keys to hold during the click.",
                ],
            ],
            "required": ["x", "y"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else {
            throw MCPToolError(message: "click requires integer x and y arguments.")
        }
        let buttonName = arguments["button"] as? String ?? "left"
        let verb = buttonName == "right" ? "right-click" : (buttonName == "middle" ? "middle-click" : "click")
        return try requestHostedTool(
            name: name,
            arguments: argumentsWithPurpose(arguments, fallback: "\(verb) at (\(x), \(y))")
        )
    }
}

// MARK: - Type text

struct TypeTool: MCPTool {
    let name = "type"
    let description = """
        Type text into whatever currently has keyboard focus. Use after `click` if you need to \
        focus a field first. Special characters supported. Does NOT post Return at the end — \
        use the `key` tool with combo='return' for that.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Text to type."],
            ],
            "required": ["text"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard arguments["text"] is String else {
            throw MCPToolError(message: "type requires a string text argument.")
        }
        return try requestHostedTool(
            name: name,
            arguments: argumentsWithPurpose(arguments, fallback: "type text into the focused field")
        )
    }
}

// MARK: - Key combo

struct KeyTool: MCPTool {
    let name = "key"
    let description = """
        Press a single key or key combination, e.g. 'return', 'escape', 'tab', 'cmd+a', \
        'cmd+shift+t', 'control+option+left'. Modifier keys: cmd, shift, option, control.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "combo": [
                    "type": "string",
                    "description": "Key combo, e.g. 'return', 'cmd+a', 'cmd+shift+left'.",
                ],
            ],
            "required": ["combo"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let combo = arguments["combo"] as? String else {
            throw MCPToolError(message: "key requires a string combo argument.")
        }
        return try requestHostedTool(
            name: name,
            arguments: argumentsWithPurpose(arguments, fallback: "press \(combo)")
        )
    }
}

// MARK: - Scroll

struct ScrollTool: MCPTool {
    let name = "scroll"
    let description = """
        Post a scroll wheel event at pixel coordinates (x, y). `dx` and `dy` are line counts \
        (positive dy = scroll up / content moves down; negative dy = scroll down).
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x": ["type": "integer"],
                "y": ["type": "integer"],
                "dx": ["type": "integer", "description": "Horizontal scroll lines. Default: 0."],
                "dy": ["type": "integer", "description": "Vertical scroll lines. Positive = up."],
            ],
            "required": ["x", "y", "dy"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int, arguments["dy"] is Int else {
            throw MCPToolError(message: "scroll requires integer x, y, and dy arguments.")
        }
        return try requestHostedTool(
            name: name,
            arguments: argumentsWithPurpose(arguments, fallback: "scroll at (\(x), \(y))")
        )
    }
}

// MARK: - Hosted forwarding

private func argumentsWithPurpose(_ arguments: [String: Any], fallback: String) -> [String: Any] {
    var forwarded = arguments
    forwarded["purpose"] = ActionPurposeContext.recentPurpose(fallback: fallback)
    return forwarded
}

private func requestHostedTool(name: String, arguments: [String: Any]) throws -> [[String: Any]] {
    switch ConfirmationClient.requestHostedTool(name: name, arguments: arguments) {
    case .succeeded(let content):
        return content
    case .failed(let message):
        throw MCPToolError(message: message)
    case .menuBarUnavailable:
        throw MCPToolError(message: """
            Relay Runner is not running or its app-side tool host is unavailable. Start Relay Runner, then retry the \(name) tool.
            """)
    }
}
