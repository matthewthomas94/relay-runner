import XCTest
@testable import relay_runner

final class RelayDesktopHostTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-desktop-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent-desktop")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    // MARK: - Policy

    func testPolicyAllowsHeadlessObservationAndRefActionsOnly() {
        XCTAssertNil(RelayDesktopCommandPolicy.validate(["snapshot", "--app", "Finder", "-i", "--compact"]))
        XCTAssertNil(RelayDesktopCommandPolicy.validate(["click", "@s1:e8", "--wait-for", "button:Done"]))
        XCTAssertNil(RelayDesktopCommandPolicy.validate(["press", "cmd+s", "--app", "Notes"]))
        XCTAssertNil(RelayDesktopCommandPolicy.validate(["status"]))

        XCTAssertEqual(RelayDesktopCommandPolicy.validate([]), .empty)
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["clipboard-get"]), .subcommand("clipboard-get"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["screenshot"]), .subcommand("screenshot"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["double-click", "@s1:e8"]), .subcommand("double-click"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["mouse-click", "--xy", "1,2"]), .subcommand("mouse-click"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["click", "@s1:e8", "--headed"]), .flag("--headed"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["press", "cmd+q", "--force=true"]), .flag("--force"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["snapshot", "--screenshot", "/tmp/x.html"]), .flag("--screenshot"))
        XCTAssertEqual(RelayDesktopCommandPolicy.validate(["snapshot", "--trace", "/tmp/t.jsonl"]), .flag("--trace"))
    }

    func testDesktopIsAnAccessibilityGatedHostedTool() {
        XCTAssertEqual(RelayHostedTool.requiredPermission(for: "desktop"), .accessibility)
        XCTAssertTrue(RelayHostedTool.isMissingPermissionFailure(
            "Could not perform the action. Accessibility permission is not granted to Relay Runner.",
            for: .accessibility
        ))
    }

    func testPerformRejectsMalformedOrForbiddenRequests() async {
        for arguments in [
            [:],
            ["argv": "snapshot"],
            ["argv": ["snapshot", ""]],
            ["argv": ["click", "@s1:e8", "--headed"]],
            ["argv": ["clipboard-set", "secret"]],
        ] as [[String: Any]] {
            do {
                _ = try await RelayDesktopHost.perform(arguments: arguments)
                XCTFail("expected rejection for \(arguments)")
            } catch let error as RelayHostedToolError {
                guard case .message(let message) = error else { return XCTFail("unexpected error") }
                XCTAssertFalse(message.isEmpty)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - Binary resolution

    func testBundledBinaryWinsOverOverrideAndPackageManagers() {
        let executableDirectory = URL(fileURLWithPath: "/Applications/Relay Runner.app/Contents/MacOS")
        let bundled = "/Applications/Relay Runner.app/Contents/MacOS/agent-desktop"
        let override = "/Users/dev/agent-desktop/target/release/agent-desktop"
        func resolve(existing: Set<String>, environment: [String: String] = [:]) -> String? {
            RelayDesktopHost.binaryURL(
                executableDirectory: executableDirectory,
                environment: environment,
                isExecutable: { existing.contains($0) }
            )?.path
        }
        XCTAssertEqual(resolve(existing: [bundled, override, "/opt/homebrew/bin/agent-desktop"], environment: ["RELAY_AGENT_DESKTOP_PATH": override]), bundled)
        XCTAssertEqual(resolve(existing: [override, "/opt/homebrew/bin/agent-desktop"], environment: ["RELAY_AGENT_DESKTOP_PATH": override]), override)
        XCTAssertEqual(resolve(existing: ["/opt/homebrew/bin/agent-desktop"], environment: ["RELAY_AGENT_DESKTOP_PATH": ""]), "/opt/homebrew/bin/agent-desktop")
        XCTAssertEqual(resolve(existing: ["/usr/local/bin/agent-desktop"]), "/usr/local/bin/agent-desktop")
        XCTAssertNil(resolve(existing: []))
    }

    func testTimeoutIsClampedToTheHostedRange() {
        XCTAssertEqual(RelayDesktopHost.timeout(from: [:]), 60)
        XCTAssertEqual(RelayDesktopHost.timeout(from: ["timeout_seconds": 0.1]), 1)
        XCTAssertEqual(RelayDesktopHost.timeout(from: ["timeout_seconds": 90]), 90)
        XCTAssertEqual(RelayDesktopHost.timeout(from: ["timeout_seconds": 10_000]), 180)
    }

    // MARK: - Running the CLI

    func testRunReturnsTheEnvelopeEvenOnNonZeroExit() async throws {
        let binary = try script(#"printf '{"ok":false,"error":{"code":"STALE_REF"}}'; exit 4"#)
        let output = try await RelayDesktopHost.run(binary: binary, argv: ["click", "@s1:e1"], timeout: 10)
        XCTAssertEqual(output, #"{"ok":false,"error":{"code":"STALE_REF"}}"#)
    }

    func testRunDrainsOutputLargerThanThePipeBuffer() async throws {
        let binary = try script("head -c 300000 /dev/zero | tr '\\0' 'a'")
        let output = try await RelayDesktopHost.run(binary: binary, argv: ["snapshot"], timeout: 10)
        XCTAssertEqual(output.count, 300_000)
    }

    func testRunReportsSilentFailuresWithStderr() async {
        let binary = try? script("echo 'permission denied' >&2; exit 3")
        guard let binary else { return XCTFail("script") }
        do {
            _ = try await RelayDesktopHost.run(binary: binary, argv: ["status"], timeout: 10)
            XCTFail("expected failure")
        } catch RelayHostedToolError.message(let message) {
            XCTAssertTrue(message.contains("status 3"), message)
            XCTAssertTrue(message.contains("permission denied"), message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRunStopsACommandThatOutlivesItsTimeout() async {
        let binary = try? script("sleep 20")
        guard let binary else { return XCTFail("script") }
        let started = Date()
        do {
            _ = try await RelayDesktopHost.run(binary: binary, argv: ["wait", "20000"], timeout: 1)
            XCTFail("expected timeout")
        } catch RelayHostedToolError.message(let message) {
            XCTAssertTrue(message.contains("did not finish within 1 s"), message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testRunReportsALaunchFailure() async {
        let missing = URL(fileURLWithPath: "/nonexistent/agent-desktop")
        do {
            _ = try await RelayDesktopHost.run(binary: missing, argv: ["status"], timeout: 1)
            XCTFail("expected failure")
        } catch RelayHostedToolError.message(let message) {
            XCTAssertTrue(message.contains("Could not start agent-desktop"), message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
