import AppKit
import XCTest
@testable import relay_runner

/// RR-408: Shift+Left/Right switch the voice target between open sessions.
final class SessionSwitchGestureTests: XCTestCase {
    private let right = SessionSwitchGesture.rightArrowKeyCode
    private let left = SessionSwitchGesture.leftArrowKeyCode

    // MARK: Gesture

    func testShiftArrowsGiveNextAndPrevious() {
        // Arrow keys arrive with .numericPad and .function set by AppKit.
        let arrowFlags: NSEvent.ModifierFlags = [.shift, .numericPad, .function]
        XCTAssertEqual(SessionSwitchGesture.direction(keyCode: right, modifierFlags: arrowFlags, isRepeat: false), .next)
        XCTAssertEqual(SessionSwitchGesture.direction(keyCode: left, modifierFlags: arrowFlags, isRepeat: false), .previous)
        XCTAssertEqual(SessionSwitchGesture.direction(keyCode: right, modifierFlags: .shift, isRepeat: false), .next)
        XCTAssertEqual(
            SessionSwitchGesture.direction(keyCode: left, modifierFlags: [.shift, .capsLock], isRepeat: false),
            .previous
        )
    }

    func testExtraModifiersPlainArrowsAndOtherKeysGiveNothing() {
        for extra: NSEvent.ModifierFlags in [.command, .option, .control, [.command, .option]] {
            for key in [right, left] {
                XCTAssertNil(SessionSwitchGesture.direction(keyCode: key, modifierFlags: [.shift, extra], isRepeat: false))
            }
        }
        for key in [right, left] {
            XCTAssertNil(SessionSwitchGesture.direction(keyCode: key, modifierFlags: [], isRepeat: false))
            XCTAssertNil(SessionSwitchGesture.direction(keyCode: key, modifierFlags: [.numericPad, .function], isRepeat: false))
        }
        // Shift+Up (126) and Shift+A (0) are not session switches.
        XCTAssertNil(SessionSwitchGesture.direction(keyCode: 126, modifierFlags: .shift, isRepeat: false))
        XCTAssertNil(SessionSwitchGesture.direction(keyCode: 0, modifierFlags: .shift, isRepeat: false))
    }

    func testKeyRepeatsAreIgnored() {
        XCTAssertNil(SessionSwitchGesture.direction(keyCode: right, modifierFlags: .shift, isRepeat: true))
        XCTAssertNil(SessionSwitchGesture.direction(keyCode: left, modifierFlags: .shift, isRepeat: true))
    }

    func testMonitorEventsEmitSessionSwitchAndNeverToggleTheBoard() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        _ = localHandler?(flagsEvent(.shift))
        _ = localHandler?(arrowEvent(left, flags: [.shift, .numericPad, .function]))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .sessionSwitch(.previous))
        _ = localHandler?(arrowEvent(right, flags: [.shift, .numericPad, .function]))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .sessionSwitch(.next))
        _ = localHandler?(flagsEvent([]))
        // The held Shift never counted as a clean tap, so a second one is not a double-tap.
        _ = localHandler?(flagsEvent(.shift))
        _ = localHandler?(flagsEvent([]))
        XCTAssertNil(gesture.poll(currentSegment: ""))

        _ = localHandler?(arrowEvent(right, flags: [.shift, .command], isRepeat: false))
        _ = localHandler?(arrowEvent(right, flags: .shift, isRepeat: true))
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    // MARK: Cycling and outcomes

    /// Stands in for AppState: three live sessions, focus stamping the voice key.
    private final class Fixture {
        var live = ["a", "b", "c"]
        var active: String? = "a"
        var recording = false
        var deferFocus = false
        var refuseFocus = false
        var pending: String?
        var voiceKey: String?
        var recordingKey: String?
        let names = ["a": "alpha", "b": "vial-qmk", "c": "relay-runner"]

        init() { voiceKey = "key-a" }

        func startRecording() { recording = true; recordingKey = voiceKey }
        func stopRecording() { recording = false }

        var coordinator: SessionSwitchCoordinator<String> {
            SessionSwitchCoordinator(
                liveIDs: { self.live },
                currentID: { self.active },
                displayName: { self.names[$0] },
                focus: { id in
                    if self.refuseFocus { return }
                    if self.deferFocus { self.pending = id; return }
                    self.active = id
                    self.voiceKey = "key-\(id)"
                },
                isFocused: { self.active == $0 },
                isPending: { self.pending == $0 },
                isRecording: { self.recording }
            )
        }
    }

    func testRepeatedNextVisitsAllSessionsInTabOrderAndWraps() {
        let fixture = Fixture()
        var visited: [String] = []
        var keys: [String?] = []
        for _ in 0..<3 {
            _ = fixture.coordinator.switchTarget(.next)
            visited.append(fixture.active ?? "")
            keys.append(fixture.voiceKey)
        }
        XCTAssertEqual(visited, ["b", "c", "a"])
        XCTAssertEqual(keys, ["key-b", "key-c", "key-a"])
    }

    func testPreviousWrapsFromFirstToLast() {
        let fixture = Fixture()
        XCTAssertEqual(fixture.coordinator.switchTarget(.previous), .switched(to: "relay-runner"))
        XCTAssertEqual(fixture.active, "c")
        XCTAssertEqual(fixture.voiceKey, "key-c")
        XCTAssertEqual(fixture.coordinator.switchTarget(.previous), .switched(to: "vial-qmk"))
        XCTAssertEqual(fixture.voiceKey, "key-b")
    }

    func testZeroOrOneLiveSessionChangesNothingAndShowsNoNotice() {
        for live in [[String](), ["a"]] {
            let fixture = Fixture()
            fixture.live = live
            for direction in [SessionSwitchDirection.next, .previous] {
                XCTAssertNil(fixture.coordinator.switchTarget(direction))
            }
            XCTAssertEqual(fixture.active, "a")
            XCTAssertEqual(fixture.voiceKey, "key-a")
        }
    }

    func testSwitchDuringRecordingKeepsTheInFlightTargetAndAppliesToTheNext() {
        let fixture = Fixture()
        fixture.startRecording()
        XCTAssertEqual(fixture.coordinator.switchTarget(.next), .nextRecording(to: "vial-qmk"))
        XCTAssertEqual(fixture.recordingKey, "key-a")
        XCTAssertEqual(fixture.voiceKey, "key-b")
        fixture.stopRecording()
        fixture.startRecording()
        XCTAssertEqual(fixture.recordingKey, "key-b")
    }

    func testDeferredSwitchSaysPendingAndNeverSwitched() {
        let fixture = Fixture()
        fixture.deferFocus = true
        XCTAssertEqual(fixture.coordinator.switchTarget(.next), .pending(to: "vial-qmk"))
        XCTAssertEqual(fixture.active, "a")
        XCTAssertEqual(fixture.voiceKey, "key-a")
    }

    func testRefusedSwitchShowsNothing() {
        let fixture = Fixture()
        fixture.refuseFocus = true
        XCTAssertNil(fixture.coordinator.switchTarget(.next))
        XCTAssertEqual(fixture.voiceKey, "key-a")
    }

    func testUnfocusedCurrentStartsAtTheEnds() {
        XCTAssertEqual(SessionSwitchCoordinator<String>.target(live: ["a", "b"], current: nil, direction: .next), "a")
        XCTAssertEqual(SessionSwitchCoordinator<String>.target(live: ["a", "b"], current: "x", direction: .previous), "b")
    }

    // MARK: Notch

    func testNoticeLabelsNameTheNewProject() {
        XCTAssertEqual(SessionSwitchNotice.switched(to: "vial-qmk").label, "Switched to · vial-qmk")
        XCTAssertEqual(SessionSwitchNotice.nextRecording(to: "vial-qmk").label, "Next recording · vial-qmk")
        XCTAssertEqual(SessionSwitchNotice.pending(to: "vial-qmk").label, "Switch pending · vial-qmk")
    }

    func testPlannerShowsTheNoticeThenReturnsToTheNormalLabelAndListeningNamesTheNewProject() {
        let notice = SessionSwitchNotice.switched(to: "vial-qmk")
        let shown = NotchVisualLabelAllowlist.presentation(for: .idle, switchNotice: notice)
        XCTAssertEqual(shown.labels, ["Switched to · vial-qmk"])
        XCTAssertEqual(shown.hoverLabel, "Switched to · vial-qmk")
        XCTAssertTrue(shown.pinsLabel)
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .idle, switchNotice: notice), ["Switched to · vial-qmk"])
        XCTAssertEqual(NotchActivityLabelPlanner.hoverLabel(for: .idle, switchNotice: notice), "Switched to · vial-qmk")

        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .idle), [])
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .recording, voiceTargetName: "vial-qmk"),
            ["Listening · vial-qmk"]
        )
    }

    func testNoticeShowsOverPlayingAndOverListening() {
        let notice = SessionSwitchNotice.switched(to: "vial-qmk")
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .speaking, playbackTargetName: "relay-runner", switchNotice: notice),
            ["Switched to · vial-qmk"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .speaking, playbackTargetName: "relay-runner"),
            ["Playing · relay-runner"]
        )
        let next = SessionSwitchNotice.nextRecording(to: "vial-qmk")
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .recording, voiceTargetName: "relay-runner", switchNotice: next),
            ["Next recording · vial-qmk"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(for: .speaking, playbackTargetName: "relay-runner", switchNotice: notice),
            "Switched to · vial-qmk"
        )
    }

    func testRepeatedPressesReplaceTheNoticeWithoutStacking() {
        let first = NotchActivityLabelPlanner.labels(for: .idle, switchNotice: .switched(to: "vial-qmk"))
        let second = NotchActivityLabelPlanner.labels(for: .idle, switchNotice: .switched(to: "relay-runner"))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second, ["Switched to · relay-runner"])
    }

    func testStartingUpStillWinsOverTheNotice() {
        let presentation = NotchVisualLabelAllowlist.presentation(
            for: .idle,
            bridgeStartingUp: true,
            switchNotice: .switched(to: "vial-qmk")
        )
        XCTAssertEqual(presentation.labels, ["Starting up..."])
    }

    // MARK: Helpers

    private func flagsEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
        )!
    }

    private func arrowEvent(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: keyCode
        )!
    }
}
