import Foundation

@main
struct RelayOrchestratorMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}
