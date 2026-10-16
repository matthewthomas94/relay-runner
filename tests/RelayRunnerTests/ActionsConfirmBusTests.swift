import Darwin
import XCTest
@testable import relay_runner

final class ActionsConfirmBusTests: XCTestCase {
    private func request(_ payload: [String: Any], from bus: ActionsConfirmBus) async throws -> [String: Any] {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = descriptors[0]
        let server = descriptors[1]
        guard client >= 0, server >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(client) }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        let sent = data.withUnsafeBytes { send(client, $0.baseAddress!, $0.count, 0) }
        XCTAssertEqual(sent, data.count)

        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            await bus.handleConnection(fd: server)
        }.value

        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = recv(client, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(received, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.prefix(max(received, 0)))) as? [String: Any])
    }

    func testGeneralSocketRequestRunsUIActivationOnMainActor() async throws {
        let machine = StateMachine()
        let bus = ActionsConfirmBus(stateMachine: machine, onActivateGeneral: { continuation in
            XCTAssertNil(continuation)
            XCTAssertTrue(Thread.isMainThread)
            let lookupWasOnMain = await Task.detached { pthread_main_np() != 0 }.value
            XCTAssertFalse(lookupWasOnMain)
            XCTAssertTrue(Thread.isMainThread)
            return .selected(message: "General switch queued.")
        })

        let reply = try await request(["type": "activate_general"], from: bus)

        XCTAssertEqual(reply["result"] as? String, "ok")
        XCTAssertEqual(reply["message"] as? String, "General switch queued.")
    }

    func testProjectSocketRequestResumesUIActivationOnMainActorAfterLookup() async throws {
        let machine = StateMachine()
        let bus = ActionsConfirmBus(stateMachine: machine, onActivateProject: { project, provider, continuation in
            XCTAssertNil(continuation)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(project, "/registered/project")
            XCTAssertEqual(provider, "claude")
            let lookupWasOnMain = await Task.detached { pthread_main_np() != 0 }.value
            XCTAssertFalse(lookupWasOnMain)
            XCTAssertTrue(Thread.isMainThread)
            return .queued(repoPath: project, message: "Project switch queued.")
        })

        let reply = try await request([
            "type": "activate_project", "project": "/registered/project", "provider": "claude",
        ], from: bus)

        XCTAssertEqual(reply["result"] as? String, "ok")
        XCTAssertEqual(reply["repo_path"] as? String, "/registered/project")
        XCTAssertEqual(reply["pending"] as? Bool, true)
        XCTAssertEqual(reply["message"] as? String, "Project switch queued.")
    }
    func testFocusOrBrowseActivationMessageTraversesSocket() async throws {
        let bus = ActionsConfirmBus(stateMachine: StateMachine(), onActivateProject: { project, _, _ in
            .activated(repoPath: project, message: "Focused the running project session; other sessions keep running.")
        })
        let reply = try await request(["type": "activate_project", "project": "/registered/project"], from: bus)
        XCTAssertEqual(reply["result"] as? String, "ok")
        XCTAssertNil(reply["pending"])
        XCTAssertEqual(reply["message"] as? String, "Focused the running project session; other sessions keep running.")
    }
    func testExplicitContinuationTraversesSocketAndMalformedInputNeverFallsBackToNavigation() async throws {
        var received: [[String: String]] = []
        let bus = ActionsConfirmBus(stateMachine: StateMachine(), onActivateProject: { _, _, continuation in
            XCTAssertNotNil(continuation); if let continuation { received.append(continuation) }; return .queued(repoPath: "/confirmed", message: "queued")
        }, onActivateGeneral: { continuation in
            XCTAssertNotNil(continuation); if let continuation { received.append(continuation) }; return .selected(message: "queued")
        })
        let continuation = ["text": "Y", "provider_session_id": "source", "native_session_id": "native"]
        for type in ["activate_project", "activate_general"] {
            let valid = try await request(["type": type, "project": "/confirmed", "continuation": continuation], from: bus)
            XCTAssertEqual(valid["result"] as? String, "ok")
            let invalid = try await request(["type": type, "project": "/confirmed", "continuation": ["text": 42]], from: bus)
            XCTAssertEqual(invalid["result"] as? String, "error")
        }
        XCTAssertEqual(received, [continuation, continuation])
    }

}
