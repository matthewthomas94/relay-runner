import Foundation

@main
struct RelayAppMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}
