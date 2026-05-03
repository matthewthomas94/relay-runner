import Foundation

@main
struct RelayActionsMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}
