import Foundation

// MCP server for Relay Runner.
//
// Implements MCP over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout,
// logs to stderr. The server is single-threaded and processes requests
// sequentially — MCP clients (the `claude` CLI) don't pipeline.
//
// The protocol layer is hand-rolled rather than depending on a Swift MCP SDK
// because the surface we use is small (initialize, tools/list, tools/call) and
// SDK churn outweighs the ~150 lines we'd save.

final class MCPServer {
    private let serverName = "relay-actions"
    private let serverVersion = "0.1.0"
    // 2024-11-05 is the MCP protocol revision we target. Newer revisions are
    // backward-compatible for the small surface we use.
    private let protocolVersion = "2024-11-05"

    private let tools: [String: any MCPTool]

    init() {
        let registered: [any MCPTool] = [
            ScreenshotTool(),
            ClickTool(),
            TypeTool(),
            KeyTool(),
            ScrollTool(),
            FrontmostAppTool(),
            ListWindowsTool(),
            ProposeActionTool(),
        ]
        var byName: [String: any MCPTool] = [:]
        for tool in registered {
            byName[tool.name] = tool
        }
        self.tools = byName
    }

    func run() async {
        log("relay-actions-mcp starting (\(tools.count) tool(s))")
        // Log the detected terminal/IDE responsible for TCC attribution. Helps
        // when debugging "I granted Screen Recording but it still fails" —
        // the user can compare the logged app name to what they actually
        // granted in System Settings.
        let parentName: String
        if let term = ParentProcess.detectTerminal() {
            log("Responsible parent for TCC (Screen Recording / Accessibility): \(term.displayName) (pid \(term.pid))")
            parentName = term.displayName
        } else {
            log("Could not identify a terminal/IDE in the parent chain — Screen Recording prompts will reference an unnamed parent.")
            log("Process chain: \(ParentProcess.dumpChain())")
            parentName = "unknown"
        }
        // Notify the menu-bar app so it can surface the per-parent permissions
        // wizard on first encounter. Fire-and-forget; if the menu-bar app
        // isn't running, the fall back is the per-action TTS pre-flight.
        ConfirmationClient.notifyParentDetected(parent: parentName)
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
        log("relay-actions-mcp exiting")
    }

    private func handleLine(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendParseError()
            return
        }

        let method = object["method"] as? String ?? ""
        // JSON-RPC id may be int, string, or null/missing (notification). Preserve the original
        // value so we send it back verbatim per spec.
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

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": [String: Any](),
                ],
                "serverInfo": [
                    "name": serverName,
                    "version": serverVersion,
                ],
            ]

        case "notifications/initialized", "notifications/cancelled":
            // Notifications — no response. Returning anything is harmless because the caller
            // checks `isNotification` before sending.
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
                // Notify the menu-bar app that a tool fired — drives the
                // perimeter glow + 10s decay window. propose_action skips this
                // here because it already calls notifyToolFired() inline (and
                // we don't want to double-notify when the user is staring at a
                // confirmation prompt). Tool failures also skip — we only
                // light up on successful actions, not error responses.
                if name != "propose_action" {
                    ConfirmationClient.notifyToolFired(toolName: name)
                }
                return ["content": content, "isError": false]
            } catch let error as MCPToolError {
                // Tool errors are reported as content + isError=true so Claude sees them inline,
                // not as a transport failure.
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

// MARK: - Logging

func log(_ message: String) {
    let line = "[relay-actions-mcp] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
