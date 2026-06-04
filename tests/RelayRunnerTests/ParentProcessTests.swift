import XCTest
@testable import relay_vision_mcp

final class ParentProcessTests: XCTestCase {
    func testBundledCodexCLIInsideTerminalResolvesToTerminal() {
        let parent = ParentProcess.detectTerminal(inExecutablePathChain: [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/bin/zsh",
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        ])

        XCTAssertEqual(parent?.displayName, "Terminal")
    }

    func testBundledClaudeCLIInsideTerminalResolvesToTerminal() {
        let parent = ParentProcess.detectTerminal(inExecutablePathChain: [
            "/Applications/Claude.app/Contents/Resources/claude",
            "/bin/zsh",
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        ])

        XCTAssertEqual(parent?.displayName, "Terminal")
    }

    func testNativeAgentAppFallsBackWhenNoTerminalHostExists() {
        let codexParent = ParentProcess.detectTerminal(inExecutablePathChain: [
            "/Applications/Codex.app/Contents/MacOS/Codex",
        ])
        let claudeParent = ParentProcess.detectTerminal(inExecutablePathChain: [
            "/Applications/Claude.app/Contents/MacOS/Claude",
        ])

        XCTAssertEqual(codexParent?.displayName, "Codex")
        XCTAssertEqual(claudeParent?.displayName, "Claude")
    }

    func testIDEHostBeatsBundledCodexCLI() {
        let parent = ParentProcess.detectTerminal(inExecutablePathChain: [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/bin/zsh",
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
        ])

        XCTAssertEqual(parent?.displayName, "Visual Studio Code")
    }
}
