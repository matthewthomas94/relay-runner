import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import relay_runner

/// RR-513: provider sign-in runs in Relay Runner's own terminal. Every run
/// here uses a fake login binary; no real Claude or Codex sign-in happens.
final class ProviderLoginTerminalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr513-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Commands

    func testClaudeAndCodexLoginCommandsRunInTheLaunchShellWithoutTerminalApp() throws {
        let claude = ProviderLoginCommand.claude(binary: "/opt/homebrew/bin/claude")
        let codex = ProviderLoginCommand.codex(binary: "/opt/homebrew/bin/codex")
        for (command, login) in [
            (claude, "exec '/opt/homebrew/bin/claude' auth login --claudeai"),
            (codex, "exec '/opt/homebrew/bin/codex' -c 'forced_login_method=\"chatgpt\"' login"),
        ] {
            XCTAssertEqual(command.executable, "/bin/bash")
            XCTAssertEqual(command.arguments.first, "-c")
            let script = try XCTUnwrap(command.arguments.last)
            XCTAssertTrue(script.hasSuffix(login), script)
            XCTAssertTrue(script.contains(ProcessManager.inheritedHostSessionScrub))
            XCTAssertFalse(script.contains("osascript"))
            XCTAssertFalse(script.contains("Terminal"))
            XCTAssertFalse(script.contains("open -a"))
            XCTAssertFalse(command.banner.isEmpty)
            let syntax = Process()
            syntax.executableURL = URL(fileURLWithPath: "/bin/bash")
            syntax.arguments = ["-n", "-c", script]
            try syntax.run()
            syntax.waitUntilExit()
            XCTAssertEqual(syntax.terminationStatus, 0, script)
        }
        XCTAssertTrue(claude.banner.contains("Pro, Max, Team or Enterprise subscription"))
    }

    func testLoginLinesPassTheProviderArgumentsIntact() throws {
        let argv = directory.appendingPathComponent("argv").path
        let fake = try script("fake-cli", """
        printf '%s\\n' "$@" > '\(argv)'
        """)
        for (command, expected) in [
            (ProviderLoginCommand.claude(binary: fake), ["auth", "login", "--claudeai"]),
            (ProviderLoginCommand.codex(binary: fake), ["-c", "forced_login_method=\"chatgpt\"", "login"]),
        ] {
            // Run only the login line; the profile lines read the real home.
            let login = try XCTUnwrap(command.arguments.last?.split(separator: "\n").last)
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/bash")
            run.arguments = ["-c", String(login)]
            try run.run()
            run.waitUntilExit()
            XCTAssertEqual(run.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOfFile: argv, encoding: .utf8).split(separator: "\n").map(String.init), expected)
        }
    }

    // MARK: - Sign-in links

    func testScannerFindsWholeLinksOnCompletedLinesOnly() {
        var scanner = ProviderLoginURLScanner()
        let url = "https://claude.ai/oauth/authorize?code=true&client_id=abc&redirect_uri=https%3A%2F%2Fconsole&state=xyz"
        XCTAssertNil(scanner.consume(Array("Opening browser to sign in\u{2026}\r\nIf it didn't open, visit: \(url.prefix(30))".utf8)))
        XCTAssertEqual(scanner.consume(Array("\(url.dropFirst(30))\r\n".utf8)), url)

        // Styled output, a trailing full stop and an OSC 8 hyperlink.
        XCTAssertEqual(scanner.consume(Array("\u{1B}[1;34mhttps://auth.openai.com/oauth/authorize?x=1\u{1B}[0m.\n".utf8)),
                       "https://auth.openai.com/oauth/authorize?x=1")
        XCTAssertEqual(scanner.consume(Array("\u{1B}]8;;https://example.com/sign-in?a=b\u{07}Sign in\u{1B}]8;;\u{07}\n".utf8)),
                       "https://example.com/sign-in?a=b")

        // A local callback server is not a sign-in page; the last link wins.
        XCTAssertNil(scanner.consume(Array("Starting local login server on http://localhost:1455.\n".utf8)))
        XCTAssertEqual(scanner.consume(Array("http://127.0.0.1:9/x https://a.example/one then https://b.example/two\n".utf8)),
                       "https://b.example/two")
    }

    func testSignInLinkPrintedByTheLoginCanBeOpenedOrCopied() throws {
        let url = "https://claude.ai/oauth/authorize?code=true&client_id=abc&state=xyz"
        let fake = try script("login-ok", """
        echo 'Opening browser to sign in...'
        echo "If the browser didn't open, visit: \(url)"
        sleep 0.2
        exit 0
        """)
        var opened: [URL] = []
        var copied: [String] = []
        let login = ProviderLoginTerminal(
            provider: .claude,
            command: ProviderLoginCommand(executable: fake, arguments: [], banner: "banner"),
            openURL: { opened.append($0) },
            copyString: { copied.append($0) }
        )

        XCTAssertEqual(try run(login), .exited(0))
        XCTAssertEqual(login.signInURL, url)
        login.openSignInURL()
        login.copySignInURL()
        XCTAssertEqual(opened, [URL(string: url)!])
        XCTAssertEqual(copied, [url])

        // A plain click on a link in the terminal goes to the same opener.
        let view = try XCTUnwrap(login.terminalView as? TerminalView)
        XCTAssertEqual(view.linkReporting, .implicit)
        XCTAssertEqual(view.linkHighlightMode, .hover)
        login.requestOpenLink(source: view, link: "https://example.com/clicked", params: [:])
        XCTAssertEqual(opened.last, URL(string: "https://example.com/clicked"))
    }

    // MARK: - Exit and cancel

    func testExitStatusOfTheLoginIsReported() throws {
        let failing = try script("login-fail", "echo 'Login failed'; exit 1")
        let login = ProviderLoginTerminal(
            provider: .codex,
            command: ProviderLoginCommand(executable: failing, arguments: [], banner: "banner")
        )
        XCTAssertEqual(try run(login), .exited(1))
        XCTAssertFalse(login.isRunning)
    }

    func testCancelStopsTheLoginAndEveryChildItStarted() throws {
        let fake = try waitingLogin(ignoresTerm: false)
        let login = ProviderLoginTerminal(
            provider: .claude,
            command: ProviderLoginCommand(executable: fake, arguments: [directory.path], banner: "banner")
        )
        let outcome = try run(login) { [self] in
            let pids = try waitForPIDs()
            XCTAssertEqual(login.childPID, pids.login)
            XCTAssertTrue(isAlive(pids.login) && isAlive(pids.child))
            login.cancel()
            XCTAssertTrue(login.isCancelling)
        }
        XCTAssertEqual(outcome, .cancelled)
        let pids = try waitForPIDs()
        XCTAssertTrue(waitUntilGone([pids.login, pids.child]), "login or its child still running")
    }

    func testCancelKillsALoginThatIgnoresTermAfterTheGracePeriod() throws {
        let fake = try waitingLogin(ignoresTerm: true)
        let login = ProviderLoginTerminal(
            provider: .codex,
            command: ProviderLoginCommand(executable: fake, arguments: [directory.path], banner: "banner"),
            killGracePeriod: 0.3
        )
        let outcome = try run(login) { [self] in
            _ = try waitForPIDs()
            login.cancel()
        }
        XCTAssertEqual(outcome, .cancelled)
        let pids = try waitForPIDs()
        XCTAssertTrue(waitUntilGone([pids.login, pids.child]), "login or its child still running")
    }

    func testReleasingARunningLoginStopsIt() throws {
        let fake = try waitingLogin(ignoresTerm: false)
        var login: ProviderLoginTerminal? = ProviderLoginTerminal(
            provider: .claude,
            command: ProviderLoginCommand(executable: fake, arguments: [directory.path], banner: "banner")
        )
        try login?.start { _ in }
        let pids = try waitForPIDs()
        login = nil
        XCTAssertTrue(waitUntilGone([pids.login, pids.child]), "login or its child still running")
    }

    // MARK: - Helpers

    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Prints a sign-in link, starts a child, and waits like a login that is
    /// waiting for the browser.
    private func waitingLogin(ignoresTerm: Bool) throws -> String {
        try script("login-wait", """
        \(ignoresTerm ? "trap '' TERM" : "")
        echo "Visit https://example.com/sign-in to continue"
        sleep 60 &
        echo $! > "$1/child.pid"
        echo $$ > "$1/login.pid"
        wait
        """)
    }

    private func run(
        _ login: ProviderLoginTerminal,
        whileRunning: (() throws -> Void)? = nil
    ) throws -> ProviderLoginOutcome? {
        let exited = expectation(description: "login exited")
        var outcome: ProviderLoginOutcome?
        try login.start {
            outcome = $0
            exited.fulfill()
        }
        try whileRunning?()
        wait(for: [exited], timeout: 10)
        return outcome
    }

    private func waitForPIDs() throws -> (login: pid_t, child: pid_t) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let login = pid("login.pid"), let child = pid("child.pid") {
                return (login, child)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("fake login did not record its pids")
        throw CocoaError(.fileNoSuchFile)
    }

    private func pid(_ name: String) -> pid_t? {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitUntilGone(_ pids: [pid_t]) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !pids.contains(where: isAlive) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
