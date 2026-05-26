import Foundation

@main
struct RelayVisionMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}
