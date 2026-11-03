import Foundation

// MCP server for Relay Desktop — accessibility-tree observation and headless
// semantic actions, backed by the bundled vercel-labs/agent-desktop CLI.
//
// Relay Actions owns physical input (click/type/scroll/key at coordinates) and
// Relay Vision owns pixels (screenshot/record). Relay Desktop sits in front of
// both: a snapshot returns the app's accessibility tree as JSON with a ref for
// every actionable element, and an action targets a ref through semantic
// accessibility calls, so the agent rarely needs a screenshot or a coordinate.
//
// Each tool builds one agent-desktop argv and forwards it over
// /tmp/relay_actions.sock to Relay Runner.app, which runs the CLI as its own
// child so Accessibility belongs to Relay Runner. Successful calls send the
// same `tool_fired` notification as the other Relay servers, so ActionGlow
// pulses identically.
//
// Implements MCP over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout,
// logs to stderr. Single-threaded; MCP clients don't pipeline.

final class MCPServer {
    private let serverName = "relay-desktop"
    private let serverVersion = "0.1.0"
    private let protocolVersion = "2024-11-05"

    private let tools: [String: any MCPTool]
    private var clientIsClaudeCode = false

    init() {
        var byName: [String: any MCPTool] = [:]
        let registered: [any MCPTool] = DesktopTools.all.map { $0 as any MCPTool } + [GetRelayInstructionsTool()]
        for tool in registered {
            byName[tool.name] = tool
        }
        self.tools = byName
    }

    func run() async {
        log("relay-desktop-mcp starting (\(tools.count) tool(s))")
        log("Relay Runner app hosts the agent-desktop CLI; this MCP helper only forwards tool requests.")
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
        log("relay-desktop-mcp exiting")
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
                // Failures also skip: the glow marks a delivered observation or
                // action, not an error response.
                if name != GetRelayInstructionsTool.toolName {
                    ConfirmationClient.notifyToolFired(toolName: name)
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

// Read-only: the full Relay Desktop rules for clients whose initialize
// instructions were truncated.
struct GetRelayInstructionsTool: MCPTool {
    static let toolName = "get_relay_instructions"
    let name = GetRelayInstructionsTool.toolName
    let description = """
        Return the full Relay Desktop rules (read-only): when to snapshot instead of screenshot, how refs, \
        surfaces, waits and retries work, and where Relay Actions or Relay Vision are still the right tool. \
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
    let line = "[relay-desktop-mcp] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
