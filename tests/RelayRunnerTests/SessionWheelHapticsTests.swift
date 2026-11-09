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
        // The Start slot and the four shortcuts are all targets.
        for slot in 0..<geometry.slotCount {
            XCTAssertEqual(target(slot: slot), .slot(slot))
        }
        XCTAssertEqual(SessionWheelHaptics.target(at: geometry.center, model: model), .center)
        XCTAssertNil(target(slot: 0, radius: geometry.segmentInnerRadius - 2))
        XCTAssertNil(target(slot: 0, offset: geometry.sliceAngle / 2), "Between wedges")
        XCTAssertNil(target(slot: 0, radius: geometry.actionRadius), "No submenu for an empty slot")

        // RR-469: one tab and Add; Add is silent while it is unavailable.
        model.refresh(sessions: [.init(id: "a", name: "A")])
        model.tabs = [.init(id: "t0", name: "Session 1", isActive: true)]
        _ = target(slot: 0)
        for index in 0..<2 {
            let arc = geometry.sessionItemArc(index, items: 2)
            let resolved = target(slot: 0, radius: geometry.actionRadius, offset: arc.start + arc.width / 2)
            XCTAssertEqual(resolved, .action(slot: 0, index: index))
        }
        model.addTabUnavailableReason = "Nine tabs open"
        let add = geometry.sessionItemArc(1, items: 2)
        XCTAssertNil(target(slot: 0, radius: geometry.actionRadius, offset: add.start + add.width / 2))
        model.addTabUnavailableReason = nil
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
        XCTAssertEqual(target(slot: 0), .slot(0))
        model.startUnavailableReason = "Session starting"
        XCTAssertNil(target(slot: 0))
    }

    @MainActor
    func testControllerConfirmsOnlyAcceptedActionsAndNeverRefreshOrDismissal() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var accepted = false
        var startAccepted = false
        var live: [SessionWheelSession] = []
        controller.tabAction = { _ in accepted }
        controller.noteAction = { _ in accepted }
        controller.startSession = {
            if startAccepted { live = [.init(id: "a", name: "A")] }
            return startAccepted
        }
        controller.openShortcut = { _ in }
        controller.focusSession = { _ in }
        controller.refresh = { model in
            model.refresh(sessions: live)
            model.tabs = live.isEmpty ? [] : [.init(id: "t0", name: "Session 1", isActive: true)]
        }
        controller.toggle()
        XCTAssertTrue(pulses.isEmpty)
        controller.refresh?(controller.model)
        controller.selectSlot(0, fromPointer: false) // Rejected launch.
        XCTAssertTrue(pulses.isEmpty)
        startAccepted = true
        controller.selectSlot(0, fromPointer: false) // Accepted launch.
        XCTAssertEqual(pulses, [.generic])
        controller.performTabItem(.control(.add)) // Rejected.
        controller.performNoteAction(.pause) // Disabled.
        controller.performNoteAction(.recording) // Rejected.
        XCTAssertEqual(pulses.count, 1)
        accepted = true
        controller.performTabItem(.control(.add))
        controller.performNoteAction(.recording)
        controller.selectSlot(0, fromPointer: false) // Session selection.
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
