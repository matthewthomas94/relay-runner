import Foundation

// MCP server for Relay App — first-party control of Relay Runner itself
// (RR-459): status, navigation, settings, sessions, Relay Remote pairing and
// Keep Awake, without screenshots or coordinate clicks.
//
// Each tool sends one `app_command` line to Relay Runner.app's command socket,
// /tmp/relay_session_control.sock (owner-only, same-uid peers; RR-456's
// session-control socket generalised), and returns the app's structured JSON
// result. Successful calls send the same `tool_fired` notification as the
// other Relay servers, so ActionGlow pulses identically.
//
// Implements MCP over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout,
// logs to stderr. Single-threaded; MCP clients don't pipeline.

final class MCPServer {
    private let serverName = "relay-app"
    private let serverVersion = "0.1.0"
    private let protocolVersion = "2024-11-05"

    private let tools: [String: any MCPTool]
    private let notify: (String) -> Void
    private var clientIsClaudeCode = false

    init(
        client: AppControlClient = AppControlClient(),
        notify: @escaping (String) -> Void = { ConfirmationClient.notifyToolFired(toolName: $0) }
    ) {
        var byName: [String: any MCPTool] = [:]
        let registered: [any MCPTool] = AppTools.all(client: client).map { $0 as any MCPTool } + [GetRelayInstructionsTool()]
        for tool in registered {
            byName[tool.name] = tool
        }
        self.tools = byName
        self.notify = notify
    }

    func run() async {
        log("relay-app-mcp starting (\(tools.count) tool(s))")
        log("Relay Runner app performs every command; this MCP helper only forwards tool requests.")
        var buffer = Data()
        do {
            for try await byte in FileHandle.standardInput.bytes {
                if byte == 0x0A {
                    if !buffer.isEmpty {
                        await handleLine(buffer)
                        buffer = Data()
                    }
                } else {
                    buffer.append(byte)
                }
            }
            if !buffer.isEmpty {
                await handleLine(buffer)
            }
        } catch {
            log("stdin read error: \(error)")
        }
        log("relay-app-mcp exiting")
    }

    private func handleLine(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendParseError()
            return
        }

        let method = object["method"] as? String ?? ""
        let id = object["id"]
        let isNotification = object["id"] == nil
        let params = object["params"] as? [String: Any] ?? [:]

        do {
            let result = try await dispatch(method: method, params: params)
            if !isNotification {
                sendResult(id: id, result: result)
            }
        } catch let error as JSONRPCError {
            if !isNotification {
                sendError(id: id, error: error)
            }
        } catch {
            if !isNotification {
                sendError(id: id, error: JSONRPCError(code: -32603, message: "Internal error: \(error)"))
            }
        }
    }

    func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            // Claude Code truncates instructions at 2048 characters, so it gets
            // the compact payload and fetches the rest with
            // `get_relay_instructions`; every other client gets the full rules.
            let clientInfo = params["clientInfo"] as? [String: Any]
            clientIsClaudeCode = clientInfo?["name"] as? String == "claude-code"
            return [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": [String: Any](),
                ],
                "serverInfo": [
                    "name": serverName,
                    "version": serverVersion,
                ],
                "instructions": clientIsClaudeCode ? Instructions.claudeCompact : Instructions.payload,
            ]

        case "notifications/initialized", "notifications/cancelled":
            return [String: Any]()

        case "ping":
            return [String: Any]()

        case "tools/list":
            let toolDescriptors: [[String: Any]] = tools.values
                .sorted(by: { $0.name < $1.name })
                .map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema,
                    ]
                }
            return ["tools": toolDescriptors]

        case "tools/call":
            guard let name = params["name"] as? String else {
                throw JSONRPCError(code: -32602, message: "Missing tool name")
            }
            guard let tool = tools[name] else {
                throw JSONRPCError(code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await tool.call(arguments: arguments)
                // get_relay_instructions only reads rules, so it never glows.
                // Failures also skip: the glow marks a delivered command, not
                // an error response.
                if name != GetRelayInstructionsTool.toolName {
                    notify(name)
                }
                return ["content": content, "isError": false]
            } catch let error as MCPToolError {
                return [
                    "content": [["type": "text", "text": error.message]],
                    "isError": true,
                ]
            }

        default:
            throw JSONRPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Response writing

    private func sendResult(id: Any?, result: Any) {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { envelope["id"] = id }
        write(envelope)
    }

    private func sendError(id: Any?, error: JSONRPCError) {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": error.code,
                "message": error.message,
            ],
        ]
        if let id { envelope["id"] = id } else { envelope["id"] = NSNull() }
        write(envelope)
    }

    private func sendParseError() {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": [
                "code": -32700,
                "message": "Parse error",
            ],
        ]
        write(envelope)
    }

    private func write(_ envelope: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes]) else {
            log("failed to serialize response")
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

// MARK: - Protocol types

struct JSONRPCError: Error {
    let code: Int
    let message: String
}

struct MCPToolError: Error {
    let message: String
}

protocol MCPTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    func call(arguments: [String: Any]) async throws -> [[String: Any]]
}

// Read-only: the full Relay App rules for clients whose initialize
// instructions were truncated.
struct GetRelayInstructionsTool: MCPTool {
    static let toolName = "get_relay_instructions"
    let name = GetRelayInstructionsTool.toolName
    let description = """
        Return the full Relay App rules (read-only): when to use these tools instead of Relay Desktop, \
        Relay Vision or Relay Actions for Relay Runner itself, and how confirmation and pairing work. \
        The initialize instructions are a compact summary.
        """

    var inputSchema: [String: Any] {
        ["type": "object", "properties": [String: Any]()]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        [["type": "text", "text": Instructions.payload]]
    }
}

// MARK: - Logging

func log(_ message: String) {
    let line = "[relay-app-mcp] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
