import AppKit
import XCTest
@testable import relay_runner

final class SessionWheelHapticsTests: XCTestCase {
    private let geometry = SessionWheelGeometry.self

    func testHoverRequiresMovementAndDeduplicatesWithAnImmediateCooldown() {
        var time: TimeInterval = 1
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let haptics = SessionWheelHaptics(now: { time }, perform: { pulses.append($0) })
        haptics.reset(at: .zero)
        haptics.hover(.center, at: .zero)
        haptics.hover(.center, at: CGPoint(x: 3, y: 0))
        XCTAssertTrue(pulses.isEmpty, "Opening under the pointer must be silent")

        haptics.hover(.slot(0), at: CGPoint(x: 10, y: 0))
        haptics.hover(.slot(0), at: CGPoint(x: 20, y: 0))
        XCTAssertEqual(pulses, [.generic])
        time += 0.02
        haptics.hover(.slot(1), at: CGPoint(x: 30, y: 0))
        time += 1
        haptics.hover(.slot(1), at: CGPoint(x: 31, y: 0))
        XCTAssertEqual(pulses, [.generic], "A suppressed tick is never queued for later")
        haptics.hover(.action(slot: 1, index: 0), at: CGPoint(x: 40, y: 0))
        XCTAssertEqual(pulses, [.generic, .generic])

        time += 1
        haptics.hover(.action(slot: 1, index: 1), at: CGPoint(x: 40, y: 0))
        XCTAssertEqual(pulses.count, 2, "A changed target under a stationary pointer is silent")
        haptics.hover(.action(slot: 1, index: 1), at: CGPoint(x: 41, y: 0))
        XCTAssertEqual(pulses.count, 3)
        haptics.hover(nil, at: nil)
        time += 1
        haptics.hover(.action(slot: 1, index: 1), at: CGPoint(x: 41, y: 0))
        XCTAssertEqual(pulses.count, 4, "Re-entering a control is a new hover")
    }

    func testPreferenceAppliesImmediatelyToHoverAndActions() {
        var time: TimeInterval = 1
        var enabled = false
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let haptics = SessionWheelHaptics(now: { time }, perform: { pulses.append($0) })
        haptics.isEnabled = { enabled }
        haptics.hover(.slot(0), at: .zero)
        haptics.activate()
        XCTAssertTrue(pulses.isEmpty)

        enabled = true
        haptics.activate()
        XCTAssertEqual(pulses, [.generic], "An accepted action is not throttled by hover")
        time += 0.02
        haptics.hover(.slot(1), at: CGPoint(x: 1, y: 0))
        XCTAssertEqual(pulses, [.generic], "Do not echo a hover immediately after activation")
        time += 1
        haptics.hover(.center, at: CGPoint(x: 2, y: 0))
        XCTAssertEqual(pulses, [.generic, .generic])
        enabled = false
        haptics.activate()
        time += 1
        haptics.hover(.slot(2), at: CGPoint(x: 3, y: 0))
        XCTAssertEqual(pulses.count, 2)
    }

    func testOnlyEnabledVisibleControlsResolveAsTargets() {
        let model = SessionWheelModel()
        func target(slot: Int, radius: CGFloat = 119, offset: CGFloat = 0) -> SessionWheelHaptics.Target? {
            let point = geometry.position(slot: slot, radius: radius, offset: offset)
            model.hover(at: point)
            return SessionWheelHaptics.target(at: point, model: model)
        }
        // The session slot and the four shortcuts are all targets.
        for slot in 0..<geometry.slotCount {
            XCTAssertEqual(target(slot: slot), .slot(slot))
        }
        XCTAssertEqual(SessionWheelHaptics.target(at: geometry.center, model: model), .center)
        XCTAssertNil(target(slot: 0, radius: geometry.segmentInnerRadius - 2))
        XCTAssertNil(target(slot: 0, offset: geometry.sliceAngle / 2), "Between wedges")

        // RR-521: the four agents are targets with no session running; a start
        // is silent while another is starting, and stopping never is.
        _ = target(slot: 0)
        func agent(_ index: Int) -> SessionWheelHaptics.Target? {
            let arc = geometry.sessionItemArc(index)
            return target(slot: 0, radius: geometry.actionRadius, offset: arc.start + arc.width / 2)
        }
        for index in 0..<4 {
            XCTAssertEqual(agent(index), .action(slot: 0, index: index))
        }
        model.startUnavailableReason = "Agent starting"
        XCTAssertNil(agent(0))
        model.refresh(sessions: [.init(id: "a", name: "A")])
        model.runningAgents = [.puck]
        model.activeAgent = .puck
        let stop = geometry.sessionGlyphPoint(0, label: "PK")
        model.hover(at: stop)
        XCTAssertEqual(SessionWheelHaptics.target(at: stop, model: model), .action(slot: 0, index: 0))
        XCTAssertNil(agent(1))
        model.startUnavailableReason = nil
        XCTAssertEqual(agent(1), .action(slot: 0, index: 1))
        XCTAssertNil(target(slot: 0, radius: geometry.wheelRadius + 4), "The radial gap is silent")

        for phase in [MeetingNoteCoordinatorPhase.idle, .recording, .paused, .transcribing] {
            model.notePhase = phase
            _ = target(slot: 3)
            for action in SessionWheelNoteAction.allCases {
                let resolved = target(slot: 3, radius: geometry.actionRadius,
                                      offset: geometry.actionOffset(action.rawValue))
                XCTAssertEqual(resolved, action.isEnabled(for: phase) ? .action(slot: 3, index: action.rawValue) : nil)
            }
        }

        _ = target(slot: 2)
        for (index, expected) in [(0, 0), (1, 0), (2, 0), (3, 0), (4, 4), (5, 5)] {
            XCTAssertEqual(target(slot: 2, radius: geometry.actionRadius, offset: geometry.actionOffset(index, subdivisions: 6)),
                           .action(slot: 2, index: expected), "The slider is one target across its subdivisions")
        }
        model.keepAwake = .enabling
        XCTAssertNil(target(slot: 2, radius: geometry.actionRadius, offset: geometry.actionOffset(4, subdivisions: 6)))
        XCTAssertEqual(target(slot: 2, radius: geometry.actionRadius, offset: geometry.actionOffset(5, subdivisions: 6)),
                       .action(slot: 2, index: 5), "Auto-play is independent of Keep Awake approval")
        model.particleFieldEnabled = false
        XCTAssertNil(target(slot: 2, radius: geometry.actionRadius, offset: geometry.actionOffset(0)))

        XCTAssertEqual(target(slot: 0), .slot(0))
        XCTAssertEqual(target(slot: 1), .slot(1), "History stays a target while a session runs")
        model.refresh(sessions: [])
        model.startUnavailableReason = "Agent starting"
        XCTAssertEqual(target(slot: 0), .slot(0), "The session slot only opens the terminal, so it is always a target")
    }

    @MainActor
    func testControllerConfirmsOnlyAcceptedActionsAndNeverRefreshOrDismissal() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var accepted = false
        var live: [SessionWheelSession] = []
        controller.agentAction = { _ in
            if accepted { live = [.init(id: "a", name: "A")] }
            return accepted
        }
        controller.noteAction = { _ in accepted }
        controller.openShortcut = { _ in }
        controller.openTerminal = {}
        controller.refresh = { model in
            model.refresh(sessions: live)
            model.runningAgents = live.isEmpty ? [] : [.puck]
        }
        controller.toggle()
        XCTAssertTrue(pulses.isEmpty)
        controller.refresh?(controller.model)
        controller.performAgentAction(.start(.puck)) // Rejected launch.
        XCTAssertTrue(pulses.isEmpty)
        controller.selectSlot(0, fromPointer: false) // Opens the terminal.
        XCTAssertEqual(pulses, [.generic])
        controller.model.startUnavailableReason = "Agent starting"
        controller.performAgentAction(.start(.puck)) // Disabled.
        controller.model.startUnavailableReason = nil
        controller.performNoteAction(.pause) // Disabled.
        controller.performNoteAction(.recording) // Rejected.
        XCTAssertEqual(pulses.count, 1)
        accepted = true
        controller.performAgentAction(.start(.puck)) // Accepted launch.
        controller.performNoteAction(.recording)
        controller.selectSlot(0, fromPointer: false) // Opens the terminal.
        controller.selectSlot(3, fromPointer: false) // Notetaker shortcut.
        XCTAssertEqual(pulses, Array(repeating: .generic, count: 5))
        XCTAssertTrue(controller.isVisible)
        controller.refresh?(controller.model)
        controller.selectCenter() // Closes the wheel.
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(pulses, Array(repeating: .generic, count: 6))
        controller.hoverFeedback(at: geometry.center, target: .center)
        controller.performNoteAction(.recording)
        controller.selectCenter()
        XCTAssertEqual(pulses.count, 6)
        controller.toggle()
        XCTAssertEqual(pulses.count, 6, "Reopening a closing wheel does not pulse")
    }
}
