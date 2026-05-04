import Foundation

// MCP server for the relay-runner orchestrator.
//
// This is a thin proxy: each MCP tool call translates to a single HTTP request
// to the Python daemon (services/orchestrator.py) on 127.0.0.1. The Swift
// surface exists so the orchestrator's tools appear in Claude Code's MCP toolbelt
// alongside relay-actions, with consistent stdio framing.
//
// Mirrors Sources/relay-actions-mcp/Server.swift's hand-rolled JSON-RPC.

final class MCPServer {
    private let serverName = "relay-orchestrator"
    private let serverVersion = "0.1.0"
    private let protocolVersion = "2024-11-05"

    private let tools: [String: any MCPTool]

    init() {
        let registered: [any MCPTool] = [
            LinkProjectTool(),
            UnlinkProjectTool(),
            ListProjectsTool(),
            DispatchIssueTool(),
            ListRunsTool(),
            GetRunTool(),
            CancelRunTool(),
        ]
        var byName: [String: any MCPTool] = [:]
        for tool in registered {
            byName[tool.name] = tool
        }
        self.tools = byName
    }

    func run() async {
        log("relay-orchestrator-mcp starting (\(tools.count) tool(s))")
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
        log("relay-orchestrator-mcp exiting")
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

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ]

        case "notifications/initialized", "notifications/cancelled":
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

// MARK: - Logging

func log(_ message: String) {
    let line = "[relay-orchestrator-mcp] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
