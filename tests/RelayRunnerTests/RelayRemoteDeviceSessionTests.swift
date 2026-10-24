import XCTest
@testable import relay_runner

final class RelayRemoteDeviceSessionTests: XCTestCase {
    private final class Gate: RemoteMicrophoneGate {
        var suspended = false
        var preserved: [Bool] = []
        func suspendForRemoteDevice() { suspended = true }
        func resumeAfterRemoteDevice(preservingGesture: Bool) {
            suspended = false
            preserved.append(preservingGesture)
        }
    }

    private final class KeepAwake: RemoteKeepAwake {
        var held = false
        var acquires = 0
        var releases = 0
        func acquire() {
            guard !held else { return }
            held = true
            acquires += 1
        }
        func release() {
            guard held else { return }
            held = false
            releases += 1
        }
    }

    private let gate = Gate()
    private let awake = KeepAwake()
    private lazy var session = RelayRemoteDeviceSession(gate: gate, keepAwake: awake)

    private func event(_ kind: RemoteDeviceEvent.Kind, _ id: String = "d1", _ name: String = "Matt's iPhone") -> RemoteDeviceEvent {
        RemoteDeviceEvent(kind, deviceID: id, deviceName: name)
    }

    func testActiveThenDisconnectedSuspendsAndResumes() {
        session.apply(event(.connected))
        XCTAssertFalse(gate.suspended)
        session.apply(event(.active))
        XCTAssertTrue(gate.suspended)
        session.apply(event(.disconnected))
        XCTAssertFalse(gate.suspended)
        XCTAssertNil(session.statusLabel)
    }

    func testUserTakeoverResumesAndMarksDeviceInactive() {
        session.apply(event(.active))
        session.userTookOver()
        XCTAssertFalse(gate.suspended)
        XCTAssertNil(session.activeDeviceID)
        XCTAssertEqual(gate.preserved, [true])
        XCTAssertEqual(session.statusLabel, "Remote: Matt's iPhone")
        XCTAssertTrue(awake.held)
        session.userTookOver()
        XCTAssertEqual(gate.preserved, [true])
    }

    func testActiveAgainAfterTakeoverSuspendsAgain() {
        session.apply(event(.active))
        session.userTookOver()
        session.apply(event(.active))
        XCTAssertTrue(gate.suspended)
    }

    func testKeepAwakeAcquiredOnConnectAndReleasedWithoutLeakAcrossReconnects() {
        session.apply(event(.connected))
        session.apply(event(.active))
        XCTAssertEqual(awake.acquires, 1)
        XCTAssertTrue(awake.held)
        for _ in 0..<3 {
            session.apply(event(.disconnected))
            XCTAssertFalse(awake.held)
            session.apply(event(.connected))
            XCTAssertTrue(awake.held)
        }
        session.apply(event(.disconnected))
        XCTAssertEqual(awake.acquires, awake.releases)
        XCTAssertFalse(awake.held)
    }

    func testAssertionHeldUntilLastDeviceDisconnects() {
        session.apply(event(.connected, "a", "A"))
        session.apply(event(.connected, "b", "B"))
        session.apply(event(.disconnected, "a", "A"))
        XCTAssertTrue(awake.held)
        XCTAssertEqual(session.statusLabel, "Remote: B")
        session.apply(event(.disconnected, "b", "B"))
        XCTAssertFalse(awake.held)
    }

    func testEventParsingAcceptsBothShapesAndIgnoresOthers() {
        let a = RemoteDeviceEvent(["source": "bridge", "state": "remote_device", "event": "active",
                                   "device_id": "d", "device_name": "Pad"])
        XCTAssertEqual(a?.kind, .active)
        XCTAssertEqual(a?.deviceName, "Pad")
        let b = RemoteDeviceEvent(["source": "remote_device", "state": "connected", "device_id": "d"])
        XCTAssertEqual(b?.kind, .connected)
        XCTAssertNil(RemoteDeviceEvent(["source": "bridge", "state": "idle"]))
        XCTAssertNil(RemoteDeviceEvent(["source": "bridge", "state": "remote_device", "event": "bogus", "device_id": "d"]))
    }

    func testNotchLabelShowsOnlyWhenStateHasNoLabelOfItsOwn() {
        let idle = NotchVisualLabelAllowlist.presentation(for: .idle, remoteDeviceLabel: "Remote: Pad")
        XCTAssertEqual(idle.labels, ["Remote: Pad"])
        let speaking = NotchVisualLabelAllowlist.presentation(for: .speaking, remoteDeviceLabel: "Remote: Pad")
        XCTAssertEqual(speaking.labels, ["Playing"])
        let gone = NotchVisualLabelAllowlist.presentation(for: .idle, remoteDeviceLabel: nil)
        XCTAssertEqual(gone.labels, [])
    }
}
