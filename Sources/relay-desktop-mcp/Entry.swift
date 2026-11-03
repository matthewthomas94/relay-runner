import Foundation

@main
struct RelayDesktopMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}
