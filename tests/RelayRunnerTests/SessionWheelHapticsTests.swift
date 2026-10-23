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
        XCTAssertEqual(pulses, [.alignment])
        time += 0.02
        haptics.hover(.slot(1), at: CGPoint(x: 30, y: 0))
        time += 1
        haptics.hover(.slot(1), at: CGPoint(x: 31, y: 0))
        XCTAssertEqual(pulses, [.alignment], "A suppressed tick is never queued for later")
        haptics.hover(.action(slot: 1, index: 0), at: CGPoint(x: 40, y: 0))
        XCTAssertEqual(pulses, [.alignment, .alignment])

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
        XCTAssertEqual(pulses, [.generic, .alignment])
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
        for slot in 0..<geometry.slotCount {
            XCTAssertEqual(target(slot: slot), .slot(slot))
        }
        XCTAssertEqual(SessionWheelHaptics.target(at: geometry.center, model: model), .center)
        XCTAssertNil(target(slot: 0, radius: geometry.segmentInnerRadius - 2))
        XCTAssertNil(target(slot: 0, offset: geometry.sliceAngle / 2), "Between wedges")
        XCTAssertNil(target(slot: 0, radius: geometry.actionRadius), "No submenu for an empty slot")

        model.refresh(sessions: [.init(id: "a", name: "A", canRecord: false, canPlay: false)])
        _ = target(slot: 0)
        for action in SessionWheelAction.allCases {
            let resolved = target(slot: 0, radius: geometry.actionRadius, offset: geometry.actionOffset(action))
            XCTAssertEqual(resolved, action == .stop ? .action(slot: 0, index: action.rawValue) : nil)
        }
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

        model.showAllSessions(at: geometry.center)
        XCTAssertEqual(target(slot: 0), .slot(0))
        XCTAssertNil(target(slot: 1), "Empty overflow slots are disabled")
        model.projects = [.init(id: "p", name: "P", path: "/projects/p"),
                          .init(id: "q", name: "Q", path: "/projects/q", isAvailable: false)]
        model.showProjects(at: geometry.center)
        XCTAssertEqual(target(slot: 0), .slot(0))
        XCTAssertNil(target(slot: 1))
        XCTAssertNil(target(slot: 2))
        model.startUnavailableReason = "Session limit reached"
        XCTAssertNil(target(slot: 0))
    }

    @MainActor
    func testControllerConfirmsOnlyAcceptedActionsAndNeverRefreshOrDismissal() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var accepted = false
        controller.sessionAction = { _, _ in accepted }
        controller.noteAction = { _ in accepted }
        controller.startProject = { _ in accepted }
        controller.openShortcut = { _ in }
        controller.toggleWorkspace = {}
        controller.focusSession = { _ in }
        controller.refresh = { model, _ in
            model.refresh(sessions: [.init(id: "a", name: "A", canPlay: false)])
            model.projects = [.init(id: "p", name: "P", path: "/projects/p")]
        }
        controller.toggle()
        XCTAssertTrue(pulses.isEmpty)
        controller.refresh?(controller.model, true)
        controller.performAction("a", .message) // Disabled.
        controller.performAction("a", .recording) // Rejected.
        controller.performNoteAction(.pause) // Disabled.
        controller.performNoteAction(.recording) // Rejected.
        XCTAssertTrue(pulses.isEmpty)

        controller.selectSlot(1, fromPointer: false) // Open the project picker.
        XCTAssertEqual(pulses, [.generic])
        controller.selectSlot(0, fromPointer: false) // Rejected launch.
        XCTAssertEqual(pulses.count, 1)
        accepted = true
        controller.selectSlot(0, fromPointer: false) // Accepted launch.
        controller.performAction("a", .recording)
        controller.performNoteAction(.recording)
        controller.selectSlot(0, fromPointer: false) // Session selection.
        controller.selectSlot(3, fromPointer: false) // Notetaker shortcut.
        controller.selectCenter()
        controller.selectSlot(1, fromPointer: false)
        controller.back()
        XCTAssertEqual(pulses, Array(repeating: .generic, count: 9))
        XCTAssertTrue(controller.isVisible)
        controller.refresh?(controller.model, false)
        controller.dismiss()
        controller.hoverFeedback(at: geometry.center, target: .center)
        controller.performNoteAction(.recording)
        controller.selectCenter()
        controller.back()
        XCTAssertEqual(pulses.count, 9)
        controller.toggle()
        XCTAssertEqual(pulses.count, 9, "Reopening a closing wheel does not pulse")
    }
}
