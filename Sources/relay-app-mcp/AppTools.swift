import Foundation

/// One request-reply exchange per call with Relay Runner.app's command socket:
/// `{"type":"app_command","id":…,"command":…,"arguments":{…}}` out, the
/// matching `{"type":"app_result","id":…,"ok":…}` back. Lines the socket
/// pushes to other clients (`session_state`) are skipped.
struct AppControlClient {
    static let defaultSocketPath = "/tmp/relay_session_control.sock"
    private static let maxReplyBytes = 4 * 1024 * 1024

    var path = ProcessInfo.processInfo.environment["RELAY_SESSION_CONTROL_SOCKET_PATH"] ?? AppControlClient.defaultSocketPath
    /// Pairing steps wait up to 10 s in the app, and a project switch can take a few seconds.
    var timeoutSeconds = 45

    func call(_ command: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let fd = UnixSocket.connect(path) else {
            throw MCPToolError(message: "Relay Runner is not running: nothing is listening on \(path). Open Relay Runner, then retry.")
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let id = UUID().uuidString.lowercased()
        let request: [String: Any] = ["type": "app_command", "id": id, "command": command, "arguments": arguments]
        guard var line = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            throw MCPToolError(message: "\(command) arguments could not be encoded as JSON.")
        }
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line) else {
            throw MCPToolError(message: "Relay Runner closed the connection before \(command) was sent.")
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count <= Self.maxReplyBytes {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let reply = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                      object["type"] as? String == "app_result", object["id"] as? String == id else { continue }
                guard object["ok"] as? Bool == true else {
                    throw MCPToolError(message: object["error"] as? String ?? "Relay Runner refused \(command).")
                }
                return object["result"] as? [String: Any] ?? [:]
            }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw MCPToolError(message: "Relay Runner did not answer \(command) within \(timeoutSeconds) seconds. Update Relay Runner if it predates Relay App.")
            }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        throw MCPToolError(message: "Relay Runner closed the connection without answering \(command).")
    }
}

/// One Relay App tool: validates what it can locally, then forwards the call
/// as the app command of the same name and returns the result as JSON text.
struct AppTool: MCPTool {
    let name: String
    let description: String
    let properties: [String: Any]
    var required: [String] = []
    /// Destructive tools refuse here, before anything reaches the app, unless `confirm` is true.
    var requiresConfirm = false
    let client: AppControlClient

    var inputSchema: [String: Any] {
        var properties = properties
        if requiresConfirm {
            properties["confirm"] = ["type": "boolean", "description": "Must be true: this tool is destructive and refuses otherwise."]
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required + (requiresConfirm ? ["confirm"] : []),
            "additionalProperties": false,
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        if requiresConfirm, (arguments["confirm"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) != true {
            throw MCPToolError(message: "Refused: \(name) is destructive. Ask the user if unsure, then pass confirm: true.")
        }
        let result = try client.call(name, arguments: arguments)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
    }
}

enum AppTools {
    private static let settingsPages = ["permissions", "speech_to_text", "text_to_speech", "general", "awareness", "relay_remote"]

    static func all(client: AppControlClient) -> [AppTool] {
        [
            AppTool(
                name: "app_status",
                description: "Report Relay Runner's state as JSON: app version and build, the session (state, project), Relay Remote (Remote mode, paired device count, Remote Login, pairing phase), privacy permissions and Keep Awake. Read-only.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "navigate",
                description: "Show a Relay Runner surface: the Workspace board, the Notetaker, the session Terminal, or Settings, optionally on a specific page. Idempotent; it only opens or focuses the surface.",
                properties: [
                    "destination": ["type": "string", "enum": ["workspace", "notetaker", "terminal", "settings"]],
                    "settings_page": ["type": "string", "enum": settingsPages, "description": "Only with destination settings."],
                ],
                required: ["destination"],
                client: client
            ),
            AppTool(
                name: "get_settings",
                description: "Read Relay Runner's effective settings (config.toml) as JSON sections stt, tts, general and awareness, plus the keys Relay Runner records itself. Read-only; contains no credentials.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "set_settings",
                description: "Apply a partial settings update through the same path as the Settings Save button, which also hot-reloads running services. Pass only the keys to change, e.g. {\"tts\": {\"rate\": 1.2}}. Unknown keys, wrong types and values the current provider or model cannot use are refused, never coerced. Idempotent: returns the changed keys (empty when nothing changed) and the effective settings.",
                properties: [
                    "settings": ["type": "object", "description": "Sections (stt, tts, general, awareness) mapping setting names to new values. Call get_settings for the names."],
                ],
                required: ["settings"],
                client: client
            ),
            AppTool(
                name: "list_projects",
                description: "List the projects registered on this Mac (id, name, availability) with the current session state. Read-only.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "select_project",
                description: "Focus a registered project as activate_project does: a running session for it is focused, otherwise its board opens. Never starts or stops a session.",
                properties: ["project_id": ["type": "string", "description": "An id from list_projects."]],
                required: ["project_id"],
                client: client
            ),
            AppTool(
                name: "start_session",
                description: "Start a session for a registered project as the Workspace Start button does, using the Mac's provider defaults. Starting the project that is already running only reports it; while another project runs it is refused with that project's name. Returns the session state; poll app_status until session is ready.",
                properties: ["project_id": ["type": "string", "description": "An id from list_projects."]],
                required: ["project_id"],
                client: client
            ),
            AppTool(
                name: "end_session",
                description: "End every running session, as the menu's End Session does. Destructive: requires confirm: true. Reports whether anything was running.",
                properties: [:],
                requiresConfirm: true,
                client: client
            ),
            AppTool(
                name: "relay_remote_devices",
                description: "List the phones paired with Relay Remote (id, name, key fingerprint, whether limited to the home network and Tailscale) and whether Remote Login is on. Read-only.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "relay_remote_unpair",
                description: "Remove a paired phone's access to this Mac, as the Settings Unpair button does. Destructive: requires confirm: true.",
                properties: ["device_id": ["type": "string", "description": "An id from relay_remote_devices."]],
                required: ["device_id"],
                requiresConfirm: true,
                client: client
            ),
            AppTool(
                name: "relay_remote_begin_pairing",
                description: "Start pairing a phone, as Settings > Relay Remote's Pair button does, and show the QR code on that page for the Relay Remote app to scan. Returns the pairing id, hosts, port and expiry; the one-time key and token stay in the QR code. Idempotent while a code is showing.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "relay_remote_pending_approval",
                description: "Report whether a phone that scanned the code is waiting for approval, with its name, id and key fingerprint, or how the last attempt ended. Read-only.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "relay_remote_approve",
                description: "Approve the phone waiting for approval, as the Settings Allow button does. Only approve a device the user expects. restrict_to_network: true is the \"Only from my home network and Tailscale\" option.",
                properties: ["restrict_to_network": ["type": "boolean", "description": "true limits the device to this Mac's home network and Tailscale; false allows it from anywhere."]],
                required: ["restrict_to_network"],
                client: client
            ),
            AppTool(
                name: "relay_remote_deny",
                description: "Decline the phone waiting for approval, as the Settings Deny button does.",
                properties: [:],
                client: client
            ),
            AppTool(
                name: "keep_awake",
                description: "Turn Keep Awake on or off, as the session wheel toggle does. Idempotent: a request matching the current state changes nothing. Reports pending states (enabling, disabling, awaiting_approval when macOS asks to allow the power helper) instead of toggling twice.",
                properties: ["on": ["type": "boolean"]],
                required: ["on"],
                client: client
            ),
        ]
    }
}
