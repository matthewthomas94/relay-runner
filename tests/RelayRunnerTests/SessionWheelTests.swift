import SwiftUI
import XCTest
@testable import relay_runner

final class SessionWheelTests: XCTestCase {
    private let geometry = SessionWheelGeometry.self
    private func makeController() -> SessionWheelController {
        SessionWheelController(haptics: .init(perform: { _ in }))
    }
    private func session(_ id: String) -> SessionWheelSession { .init(id: id, name: id) }
    private func tabs(_ count: Int, active: Int = 0, off: Set<Int> = []) -> [SessionWheelTab] {
        (0..<count).map { .init(id: "t\($0)", name: "PM \($0 + 1)", isActive: $0 == active, isLive: !off.contains($0)) }
    }
    private var bounds: CGRect { CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter)) }
    private func itemPoint(_ index: Int, of count: Int) -> CGPoint {
        let arc = geometry.sessionItemArc(index, items: count)
        return geometry.position(slot: 0, radius: geometry.actionRadius, offset: arc.start + arc.width / 2)
    }

    func testTheOneSessionSlotSurvivesRefreshAndIsReusedOnceEmpty() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a"), session("b")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.refresh(sessions: [session("a")])
        XCTAssertEqual(model.slots[0]?.id, "a")
        XCTAssertEqual(model.hoveredSession?.id, "a")
        model.refresh(sessions: [])
        XCTAssertNil(model.slots[0])
        XCTAssertNil(model.hoveredSession)
        model.refresh(sessions: [session("c")])
        XCTAssertEqual(model.slots[0]?.id, "c")
        XCTAssertEqual(model.slots.count, 5)
        XCTAssertEqual(model.slots.compactMap { $0 }.count, 1, "Only one session slot")
    }

    /// RR-469: every tab segment and tab control is reachable across the radial
    /// gap, including the segments that reach over History and Workspace.
    func testEveryTabSegmentAndControlIsReachableAcrossTheRadialGap() {
        for count in 1...9 {
            let model = SessionWheelModel()
            model.refresh(sessions: [session("pm")])
            model.tabs = tabs(count)
            model.hover(at: geometry.position(slot: 0, radius: 119))
            XCTAssertEqual(model.hoveredSlot, 0)
            model.hover(at: geometry.position(slot: 0, radius: (geometry.wheelRadius + geometry.actionInnerRadius) / 2))
            XCTAssertEqual(model.hoveredSession?.id, "pm")
            XCTAssertNil(model.hoveredSessionItem)
            let items = model.sessionItems
            XCTAssertEqual(items.count, count + 3)
            for (index, item) in items.enumerated() {
                let point = itemPoint(index, of: items.count)
                model.hover(at: point)
                XCTAssertEqual(model.hoveredSlot, 0, "\(count) tabs, item \(index)")
                XCTAssertEqual(model.hoveredSessionItem, item, "\(count) tabs, item \(index)")
                let arc = geometry.sessionItemArc(index, items: items.count)
                let shape = SessionWheelSector(slot: 0, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius,
                                               arcStart: arc.start, arcWidth: arc.width)
                XCTAssertTrue(shape.path(in: bounds).contains(point))
                XCTAssertTrue(geometry.contains(point, submenuSlot: 0, sessionItems: items.count))
            }
        }
    }

    /// RR-469: three tabs or fewer keep the standard size over the session
    /// cell; more grow along the arc, up to the far ends of History and
    /// Workspace at nine, never reaching Settings or Notetaker.
    func testSessionSubmenuIsStandardUpToThreeTabsAndWrapsToHistoryAndWorkspaceAtNine() {
        for count in 1...3 {
            XCTAssertEqual(geometry.sessionSubmenuSpan(items: count + 3), 1)
        }
        var previous: CGFloat = 1
        for count in 4...9 {
            let span = geometry.sessionSubmenuSpan(items: count + 3)
            XCTAssertGreaterThan(span, previous)
            previous = span
        }
        XCTAssertEqual(geometry.sessionSubmenuSpan(items: 12), 3, accuracy: 0.0001)
        // Each segment stays at least as wide as a standard one.
        for count in 1...9 {
            XCTAssertGreaterThanOrEqual(geometry.sessionItemArc(0, items: count + 3).width,
                                        geometry.sliceAngle / 6 - 0.0001)
        }
        // The full arc covers History (1) and Workspace (4) but not Settings (2) or Notetaker (3).
        let first = geometry.sessionItemArc(0, items: 12)
        let last = geometry.sessionItemArc(11, items: 12)
        XCTAssertEqual(first.start, -1.5 * geometry.sliceAngle, accuracy: 0.0001)
        XCTAssertEqual(last.start + last.width, 1.5 * geometry.sliceAngle, accuracy: 0.0001)
        for slot in [SessionWheelShortcut.settings.rawValue, SessionWheelShortcut.noteTaker.rawValue] {
            let point = geometry.position(slot: slot, radius: geometry.actionRadius)
            XCTAssertNil(geometry.sessionItem(at: point, items: 12))
            XCTAssertFalse(geometry.contains(point, submenuSlot: 0, sessionItems: 12))
        }
        for slot in [SessionWheelShortcut.history.rawValue, SessionWheelShortcut.workspace.rawValue] {
            XCTAssertNotNil(geometry.sessionItem(at: geometry.position(slot: slot, radius: geometry.actionRadius), items: 12))
            XCTAssertNil(geometry.sessionItem(at: geometry.position(slot: slot, radius: geometry.actionRadius), items: 6),
                         "A standard submenu stays over its own cell")
        }
    }

    func testWheelAndSubmenuGapsAreInsideTheClickArea() {
        XCTAssertTrue(geometry.contains(geometry.center))
        for slot in 0..<geometry.slotCount {
            let segmentGap = geometry.position(slot: slot, radius: 120, offset: geometry.sliceAngle / 2)
            XCTAssertTrue(geometry.contains(segmentGap))
            XCTAssertTrue(geometry.contains(geometry.position(slot: slot, radius: geometry.hubRadius + 4)))
            XCTAssertTrue(geometry.contains(geometry.position(slot: slot, radius: geometry.wheelRadius - 4)))

            for radius in [geometry.wheelRadius + 4, geometry.actionRadius, geometry.actionOuterRadius + 4] {
                let point = geometry.position(slot: slot, radius: radius)
                XCTAssertTrue(geometry.contains(point, submenuSlot: slot))
                XCTAssertFalse(geometry.contains(point), "An absent submenu is outside the wheel")
                XCTAssertFalse(geometry.contains(point, submenuSlot: (slot + 1) % geometry.slotCount))
            }
            let outside = geometry.position(slot: slot, radius: geometry.actionOuterRadius + geometry.segmentGap + 1)
            XCTAssertFalse(geometry.contains(outside, submenuSlot: slot))
        }
    }

    func testRootHasFiveSegmentsWithTheSessionOnTopAndFourShortcutsAround() {
        let model = SessionWheelModel()
        XCTAssertEqual(geometry.slotCount, 5)
        XCTAssertEqual((0..<5).filter { model.shortcut(at: $0) == nil }, [0])
        XCTAssertEqual([1, 2, 3, 4].compactMap { model.shortcut(at: $0) }, [.history, .settings, .noteTaker, .workspace])
        let top = geometry.position(slot: 0, radius: 119)
        XCTAssertEqual(top.x, geometry.center.x, accuracy: 0.0001)
        XCTAssertLessThan(top.y, geometry.center.y)
        let positions = [1, 2, 3, 4].map { geometry.position(slot: $0, radius: 119) }
        // History and Settings on the right, Notetaker and Workspace on the left.
        XCTAssertTrue(positions[0].x > geometry.center.x && positions[1].x > geometry.center.x)
        XCTAssertTrue(positions[2].x < geometry.center.x && positions[3].x < geometry.center.x)
        // Settings and Notetaker sit on the lower half; History and Workspace on the upper.
        XCTAssertTrue(positions[1].y > geometry.center.y && positions[2].y > geometry.center.y)
        XCTAssertTrue(positions[0].y < geometry.center.y && positions[3].y < geometry.center.y)
        XCTAssertEqual(SessionWheelShortcut.history.title, "History")
        XCTAssertEqual(SessionWheelShortcut.history.symbol, "clock.arrow.circlepath")
        XCTAssertEqual(SessionWheelSessionSlot.title, "Terminal")
        XCTAssertEqual(SessionWheelSessionSlot.symbol, "apple.terminal")
        model.refresh(sessions: [session("a")])
        XCTAssertEqual(model.slots[0]?.id, "a")
        XCTAssertTrue([1, 2, 3, 4].allSatisfy { model.slots[$0] == nil })
    }

    /// RR-445: no more-sessions slot or all-sessions page. With no session the
    /// session slot starts the general session.
    func testOnlyTheSessionSlotStartsASessionAndOnlyWhileNoneRuns() {
        let model = SessionWheelModel()
        XCTAssertEqual((0..<5).filter(model.isStartSlot), [0])
        model.refresh(sessions: ["a", "b"].map(session))
        XCTAssertEqual(model.slots[0]?.id, "a")
        XCTAssertTrue((0..<5).allSatisfy { !model.isStartSlot($0) })
        model.refresh(sessions: [])
        XCTAssertEqual((0..<5).filter(model.isStartSlot), [0])
    }

    func testNoteControlsRetainHoverAcrossGapAndSessionRefresh() {
        let model = SessionWheelModel()
        let slot = SessionWheelShortcut.noteTaker.rawValue
        model.hover(at: geometry.position(slot: slot, radius: 119))
        XCTAssertEqual(model.submenuSlot, slot)
        model.hover(at: geometry.position(slot: slot, radius: geometry.wheelRadius + 4))
        XCTAssertTrue(model.isHoveringNoteTaker)
        for action in SessionWheelNoteAction.allCases {
            model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius,
                                              offset: geometry.actionOffset(action.rawValue)))
            model.refresh(sessions: [session("a")])
            XCTAssertEqual(model.hoveredNoteAction, action)
            XCTAssertNil(model.hoveredSessionItem)
            XCTAssertEqual(model.submenuSlot, slot)
        }
    }

    func testNoteControlsFollowCaptureLifecycle() {
        for phase in [MeetingNoteCoordinatorPhase.idle, .saved] {
            XCTAssertTrue(SessionWheelNoteAction.recording.isEnabled(for: phase))
            XCTAssertEqual(SessionWheelNoteAction.recording.symbol(for: phase), "mic.fill")
            XCTAssertFalse(SessionWheelNoteAction.cancel.isEnabled(for: phase))
            XCTAssertFalse(SessionWheelNoteAction.pause.isEnabled(for: phase))
        }
        for phase in [MeetingNoteCoordinatorPhase.recording, .paused] {
            XCTAssertTrue(SessionWheelNoteAction.recording.isEnabled(for: phase))
            XCTAssertEqual(SessionWheelNoteAction.recording.symbol(for: phase), "checkmark")
            XCTAssertTrue(SessionWheelNoteAction.cancel.isEnabled(for: phase))
            XCTAssertTrue(SessionWheelNoteAction.pause.isEnabled(for: phase))
        }
        for phase in [MeetingNoteCoordinatorPhase.preparing, .transcribing, .stopping, .interrupted, .error] {
            XCTAssertFalse(SessionWheelNoteAction.recording.isEnabled(for: phase))
            XCTAssertFalse(SessionWheelNoteAction.pause.isEnabled(for: phase))
            XCTAssertFalse(SessionWheelNoteAction.cancel.isEnabled(for: phase))
        }
        XCTAssertFalse(SessionWheelNoteAction.recording.isEnabled(for: .cancelling))
        XCTAssertFalse(SessionWheelNoteAction.pause.isEnabled(for: .cancelling))
        XCTAssertTrue(SessionWheelNoteAction.cancel.isEnabled(for: .cancelling), "Can retry cancellation")
        XCTAssertEqual(SessionWheelNoteAction.cancel.symbol(for: .recording), "xmark")
        XCTAssertEqual(SessionWheelNoteAction.recording.title(for: .recording), "Save note")
        let positions = [SessionWheelNoteAction.pause, .recording, .cancel].map {
            geometry.position(slot: 3, radius: geometry.actionRadius, offset: geometry.actionOffset($0.rawValue)).x
        }
        XCTAssertEqual(positions, positions.sorted(), "Pause/Resume, Start/Save, Cancel read left to right")
        XCTAssertEqual(SessionWheelNoteAction.pause.title(for: .paused), "Resume Notetaker")
        XCTAssertEqual(SessionWheelNoteAction.pause.symbol(for: .paused), "play.fill")
        XCTAssertEqual(SessionWheelNoteAction.pause.symbol(for: .recording), "pause.fill")
    }

    @MainActor
    func testShortcutsAndNoteActionsKeepTheWheelOpenAndRespectDisabledStates() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var phase = MeetingNoteCoordinatorPhase.idle
        controller.refresh = { model in model.notePhase = phase }
        var shortcuts: [SessionWheelShortcut] = []
        controller.openShortcut = { shortcuts.append($0) }
        var actions: [SessionWheelNoteAction] = []
        controller.noteAction = { action in
            actions.append(action)
            switch action {
            case .recording: phase = phase.ownsForeground ? .transcribing : .recording
            case .pause: phase = phase == .paused ? .recording : .paused
            case .cancel: phase = .idle
            }
            return true
        }
        controller.toggle()
        for slot in [4, 3, 2, 1] {
            controller.selectSlot(slot, fromPointer: false)
            XCTAssertTrue(controller.isVisible)
        }
        XCTAssertEqual(shortcuts, [.workspace, .noteTaker, .settings, .history])
        controller.performNoteAction(.pause)
        controller.performNoteAction(.cancel)
        XCTAssertTrue(actions.isEmpty)
        controller.model.hover(at: geometry.position(slot: 3, radius: 119))
        for action in [SessionWheelNoteAction.recording, .pause, .pause, .cancel, .recording, .recording] {
            controller.performNoteAction(action)
            XCTAssertTrue(controller.isVisible)
            XCTAssertEqual(controller.model.notePhase, phase)
            XCTAssertEqual(controller.model.submenuSlot, 3)
        }
        XCTAssertEqual(actions, [.recording, .pause, .pause, .cancel, .recording, .recording])
        controller.performNoteAction(.recording)
        controller.performNoteAction(.cancel)
        XCTAssertEqual(actions.count, 6, "Cannot stop or cancel while transcribing")
        controller.dismiss()
        controller.selectSlot(3, fromPointer: false)
        XCTAssertEqual(shortcuts.count, 4)
    }

    @MainActor
    func testWheelStaysAboveWorkspaceWhenShortcutTabsRetakeKeyboardFocus() async throws {
        _ = NSApplication.shared
        let workspace = BoardOverlayPanel()
        workspace.keyEligible = true
        let controller = makeController()
        controller.openShortcut = { _ in workspace.makeKeyAndOrderFront(nil) }
        defer {
            controller.dismiss()
            workspace.orderOut(nil)
        }
        controller.toggle()
        let wheel = try XCTUnwrap(NSApp.windows.first {
            String(describing: type(of: $0)) == "SessionWheelPanel" && $0.isVisible
        })

        for shortcut in [SessionWheelShortcut.noteTaker, .settings, .history] {
            controller.selectSlot(shortcut.rawValue, fromPointer: false)
            // SwiftUI's tab change re-applies keyboard focus after the shortcut
            // has already brought the wheel forward.
            await Task.yield()
            workspace.makeKeyAndOrderFront(nil)
            workspace.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(25))
            let orderedWindows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]).compactMap { $0[kCGWindowNumber as String] as? Int }
            XCTAssertLessThan(
                try XCTUnwrap(orderedWindows.firstIndex(of: wheel.windowNumber)),
                try XCTUnwrap(orderedWindows.firstIndex(of: workspace.windowNumber)),
                "\(shortcut.title) must not cover the wheel when it takes keyboard focus"
            )
            XCTAssertTrue(controller.isVisible)
            XCTAssertTrue(workspace.keyEligible)
        }
    }

    func testContourLabelsStayUprightAndFitInsideEveryThinActionSegment() {
        let bounds = CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter))
        for slot in 0..<geometry.slotCount {
            for action in 0..<3 {
                let rotation = geometry.actionLabelRotation(slot: slot, index: action)
                let center = geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(action))
                XCTAssertLessThanOrEqual(abs(rotation), .pi / 2, "Labels must never turn upside down")
                let radialAngle = CGFloat(slot) * geometry.sliceAngle + geometry.actionOffset(action)
                XCTAssertEqual(sin(radialAngle) * cos(rotation) - cos(radialAngle) * sin(rotation), 0, accuracy: 0.0001)
                let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius, subdivision: action)
                // Include padding in the check so the labels do not crowd the rounded edges.
                let halfWidth = geometry.actionLabelSize.width / 2 + 2
                let halfHeight = geometry.actionLabelSize.height / 2 + 2
                for x in [-halfWidth, halfWidth] {
                    for y in [-halfHeight, halfHeight] {
                        let corner = CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                                             y: center.y + x * sin(rotation) + y * cos(rotation))
                        XCTAssertTrue(shape.path(in: bounds).contains(corner), "Label clips at slot \(slot), action \(action)")
                    }
                }
            }
        }
    }

    func testCenterAndLeavingTheWheelClearHover() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.center)
        XCTAssertNil(model.hoveredSlot)
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: CGPoint(x: -30, y: -30))
        XCTAssertNil(model.hoveredSlot)
        XCTAssertNil(model.hoveredSessionItem)
    }

    func testStoppedSessionLosesItsTabControlsImmediately() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.tabs = tabs(1)
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: itemPoint(1, of: 4))
        XCTAssertEqual(model.hoveredSessionItem, .control(.add))
        model.refresh(sessions: [])
        XCTAssertNil(model.hoveredSession)
        XCTAssertNil(model.hoveredSessionItem)
    }

    func testReplacementSessionDoesNotInheritTheStoppedSessionsHoveredControl() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.tabs = tabs(1)
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: itemPoint(3, of: 4))
        XCTAssertEqual(model.hoveredSessionItem, .control(.turnOff))
        model.refresh(sessions: [session("b")])
        XCTAssertEqual(model.slots[0]?.id, "b")
        XCTAssertNil(model.hoveredSlot)
        XCTAssertNil(model.hoveredSessionItem)
    }

    @MainActor
    func testCenterClosesTheWheel() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.startSession = { XCTFail("The centre never starts a session"); return false }

        controller.toggle()
        controller.selectCenter()
        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testSessionSelectionKeepsWheelOpenAndRefreshesFocus() {
        _ = NSApplication.shared
        for isFocused in [false, true] {
            for fromPointer in [false, true] {
                let controller = makeController()
                defer { controller.dismiss() }
                var focused = isFocused
                controller.refresh = { model in
                    model.refresh(sessions: [.init(id: "a", name: "Project A", isFocused: focused)])
                }
                var selections: [String] = []
                controller.focusSession = { id in
                    XCTAssertTrue(controller.isVisible)
                    focused = true
                    selections.append(id)
                }
                controller.toggle()
                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertTrue(controller.isVisible)
                XCTAssertEqual(controller.model.slots[0]?.isFocused, true)
                XCTAssertEqual(selections, ["a"])

                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertTrue(controller.isVisible)
                XCTAssertEqual(selections, ["a", "a"])
                controller.dismiss()
                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertEqual(selections.count, 2)
            }
        }
    }

    /// RR-445: the empty first slot starts the general session directly; there
    /// is no project picker, and the wheel stays open on the new session.
    @MainActor
    func testStartSlotStartsTheGeneralSessionAndKeepsWheelOpen() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var live: [SessionWheelSession] = []
        controller.refresh = { model in model.refresh(sessions: live) }
        var starts = 0
        controller.startSession = {
            starts += 1
            live = [self.session("general")]
            return true
        }
        controller.toggle()
        for shortcut in [1, 2, 3, 4] { controller.selectSlot(shortcut, fromPointer: false) }
        XCTAssertEqual(starts, 0, "Only the session slot starts a session")
        controller.model.startUnavailableReason = "Finish taking notes first"
        controller.selectSlot(0, fromPointer: false)
        XCTAssertEqual(starts, 0)
        controller.model.startUnavailableReason = nil
        controller.selectSlot(0, fromPointer: false)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.slots[0]?.id, "general")
        XCTAssertTrue((0..<5).allSatisfy { !controller.model.isStartSlot($0) })
        controller.selectSlot(0, fromPointer: false)
        XCTAssertEqual(starts, 1, "Selecting the running session focuses it")
    }

    @MainActor
    func testFailedStartShowsANoticeAndLeavesTheStartSlot() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model in model.refresh(sessions: []) }
        controller.startSession = { false }
        controller.toggle()
        controller.selectSlot(0, fromPointer: false)
        XCTAssertEqual(controller.model.notice, "Couldn't start session")
        XCTAssertTrue(controller.model.isStartSlot(0))
        XCTAssertTrue(controller.isVisible)
    }

    func testWheelStartsAtCursorAndKeepsOuterControlsInsideEveryDisplayEdge() {
        let display = CGRect(x: -1600, y: -200, width: 1440, height: 900)
        let cursor = CGPoint(x: -900, y: 250)
        let centered = geometry.frame(at: cursor, visibleFrame: display)
        XCTAssertEqual(centered.midX, cursor.x)
        XCTAssertEqual(centered.midY, cursor.y)
        for x in [display.minX, display.maxX] {
            for y in [display.minY, display.maxY] {
                XCTAssertTrue(display.contains(geometry.frame(at: CGPoint(x: x, y: y), visibleFrame: display)))
            }
        }
        let small = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = geometry.frame(at: .zero, visibleFrame: small)
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 300))
        XCTAssertTrue(small.contains(frame))
    }

    /// RR-469: Add is disabled at nine tabs, Turn off needs another live tab,
    /// and the wheel has no Play/Replay, Record or Stop session controls.
    func testTabControlsReflectTheTabLimitAndLiveTabs() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("pm")])
        model.tabs = tabs(1)
        XCTAssertTrue(model.isEnabled(.add))
        XCTAssertTrue(model.isEnabled(.remove))
        XCTAssertFalse(model.isEnabled(.turnOff), "The only live tab cannot be turned off")
        model.tabs = tabs(2, off: [1])
        XCTAssertFalse(model.isEnabled(.turnOff))
        model.tabs = tabs(2)
        XCTAssertTrue(model.isEnabled(.turnOff))
        model.tabs = tabs(9)
        model.addTabUnavailableReason = "Nine tabs open"
        XCTAssertFalse(model.isEnabled(.add))
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: itemPoint(9, of: 12))
        XCTAssertEqual(model.hoveredSessionItem, .control(.add))
        XCTAssertEqual(model.hoverDescriptor(at: itemPoint(9, of: 12)), "Nine tabs open")
        XCTAssertEqual(SessionWheelTabControl.allCases, [.add, .remove, .turnOff])
        XCTAssertEqual(model.sessionItems.compactMap(\.tab).map(\.name), (1...9).map { "PM \($0)" })
    }

    @MainActor
    func testTabSegmentsAndControlsKeepTheWheelOpen() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var live = tabs(1)
        var performed: [SessionWheelSessionItem] = []
        controller.refresh = { model in
            model.refresh(sessions: live.isEmpty ? [] : [.init(id: "pm", name: "PM 1", isFocused: true)])
            model.tabs = live
            model.addTabUnavailableReason = live.count >= 9 ? "Nine tabs open" : nil
        }
        controller.tabAction = { item in
            performed.append(item)
            switch item {
            case .control(.add):
                live = live.map { var tab = $0; tab.isActive = false; return tab }
                live.append(.init(id: "t\(live.count)", name: "PM \(live.count + 1)", isActive: true))
            case .tab(let tab):
                live = live.map { var other = $0; other.isActive = other.id == tab.id; return other }
            case .control(.remove), .control(.turnOff):
                live.removeAll { $0.isActive }
                if !live.isEmpty { live[0].isActive = true }
            }
            return true
        }
        controller.toggle()
        for _ in 0..<8 { controller.performTabItem(.control(.add)) }
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.tabs.count, 9)
        XCTAssertFalse(controller.model.isEnabled(.add))
        controller.performTabItem(.control(.add))
        XCTAssertEqual(controller.model.tabs.count, 9, "A tenth tab changes nothing")
        XCTAssertEqual(performed.count, 8)

        controller.performTabItem(.tab(controller.model.tabs[2]))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.tabs.first(where: \.isActive)?.id, "t2")
        controller.performTabItem(.control(.remove))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.tabs.count, 8)
        XCTAssertNotNil(controller.model.tabs.first(where: \.isActive), "Removing the active tab moves activity to another live tab")
    }

    @MainActor
    func testRefusedTabActionShowsANotice() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model in
            model.refresh(sessions: [.init(id: "pm", name: "PM 1", isFocused: true)])
            model.tabs = [.init(id: "t0", name: "PM 1", isActive: true)]
        }
        controller.tabAction = { _ in false }
        controller.toggle()
        controller.performTabItem(.control(.add))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.notice, "Couldn't add a tab")
    }

    func testWorkspaceGlyphUsesNotchColoursAndMotionForEveryStatus() {
        let motion = NotchContentMotion()
        for status in [NotchSessionStatus.notWorking, .working, .listening, .paused, .playing] {
            let still = motion.renderedGlyphDots(status: status, now: 0.2, reduceMotion: true)
            XCTAssertEqual(still.map(\.center), status.glyph.dots.map { CGPoint(x: $0.x, y: $0.y) })
            XCTAssertEqual(still.map(\.color), status.glyph.dots.map { $0.color.rgb })
            let animated = motion.renderedGlyphDots(status: status, now: 0.2, reduceMotion: false)
            XCTAssertEqual(animated.count, still.count)
            if status.animatesGlyphMotion {
                XCTAssertNotEqual(animated.map(\.center), still.map(\.center))
            } else {
                XCTAssertEqual(animated, still)
            }
        }
        let waiting = motion.renderedGlyphDots(status: .playing, now: 0, reduceMotion: true)
        XCTAssertEqual(waiting.filter { $0.color == NotchStatusDotColor.blue.rgb }.count, 8)
        let recording = motion.renderedGlyphDots(status: .listening, now: 0, reduceMotion: true)
        XCTAssertEqual(recording.filter { $0.color == NotchStatusDotColor.orange.rgb }.count, 8)
    }

    @MainActor
    func testCloseGlyphIsACross() throws {
        let renderer = ImageRenderer(content: SessionWheelCloseGlyph().background(.black))
        renderer.scale = 8
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func brightness(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x * 8, y: y * 8)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        XCTAssertGreaterThan(brightness(12, 12), 0.9)
        XCTAssertGreaterThan(brightness(8, 8), 0.9)
        XCTAssertGreaterThan(brightness(16, 16), 0.9)
        XCTAssertLessThan(brightness(16, 12), 0.1, "Diagonal arms only")
    }

    private func arcPoint(_ angle: CGFloat, radius: CGFloat? = nil) -> CGPoint {
        // `SessionWheelGeometry.angle(at:)` is measured from slot 0's leading edge.
        geometry.position(slot: 0, radius: radius ?? geometry.actionRadius, offset: angle - geometry.sliceAngle / 2)
    }

    func testSettingsArcMapsTwoThirdsToIntensityAndClampsWithoutWraparound() {
        let intensity = SessionWheelIntensity.self
        let slot = SessionWheelShortcut.settings.rawValue
        XCTAssertEqual(intensity.slot, slot)
        XCTAssertEqual(geometry.angle(at: arcPoint(1)), 1, accuracy: 0.0001)
        // The slider keeps two thirds; the toggles share the remaining third.
        XCTAssertGreaterThan(intensity.maxAngle, CGFloat(slot) * geometry.sliceAngle)
        XCTAssertLessThan(intensity.minAngle, CGFloat(slot) * geometry.sliceAngle + geometry.sliceAngle * 2 / 3)
        XCTAssertGreaterThan(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(0)).y,
                             geometry.center.y, "The high end sits towards the sessions on the right")
        XCTAssertLessThan(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(2)).x,
                          geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(0)).x)

        for (angle, expected) in [(intensity.maxAngle, 1.0), (intensity.minAngle, 0.1),
                                  (intensity.maxAngle - 0.3, 1.0), (intensity.minAngle + 0.3, 0.1),
                                  ((intensity.maxAngle + intensity.minAngle) / 2, 0.55)] {
            let model = SessionWheelModel()
            XCTAssertEqual(model.adjustIntensity(to: arcPoint(angle)), expected, accuracy: 0.0001, "\(angle)")
        }
        var previous = 1.0
        for step in 0...200 {
            let angle = intensity.maxAngle + (intensity.minAngle - intensity.maxAngle) * CGFloat(step) / 200
            let value = intensity.value(forAngle: angle)
            XCTAssertLessThanOrEqual(value, previous)
            XCTAssertEqual(value, intensity.quantized(value))
            XCTAssertEqual((value * 20).rounded(), value * 20, accuracy: 0.0001, "Stays on 0.05 steps")
            XCTAssertEqual(intensity.angle(for: value), intensity.angle(for: intensity.quantized(value)))
            previous = value
        }
        for value in stride(from: 0.1, through: 1.0, by: 0.05) {
            XCTAssertEqual(intensity.value(forAngle: intensity.angle(for: value)), intensity.quantized(value), accuracy: 0.0001)
        }
        XCTAssertEqual(intensity.quantized(0), 0.1)
        XCTAssertEqual(intensity.quantized(1.4), 1.0)
        XCTAssertEqual(intensity.quantized(0.62), 0.6)
        XCTAssertEqual(intensity.percent(0.65), "65%")
    }

    func testIntensityDragIsContinuousAndNeverJumpsAcrossTheEnds() {
        let intensity = SessionWheelIntensity.self
        let middle = (intensity.maxAngle + intensity.minAngle) / 2
        for direction in [-1.0, 1.0] as [CGFloat] {
            let model = SessionWheelModel()
            var previous = model.adjustIntensity(to: arcPoint(middle))
            XCTAssertTrue(model.isAdjustingIntensity)
            // Circle the whole wheel past an end, including far from the arc and near the centre.
            for step in 1...144 {
                let radius: CGFloat = step % 3 == 0 ? 40 : step % 3 == 1 ? 330 : geometry.actionRadius
                let value = model.adjustIntensity(to: arcPoint(middle + direction * CGFloat(step) * .pi / 72, radius: radius))
                XCTAssertTrue(direction < 0 ? value >= previous : value <= previous, "step \(step)")
                previous = value
            }
            XCTAssertEqual(previous, direction < 0 ? 1.0 : 0.1)
            // Reversing leaves the clamped end immediately.
            let end = direction < 0 ? intensity.maxAngle : intensity.minAngle
            model.adjustIntensity(to: arcPoint(end))
            let back = model.adjustIntensity(to: arcPoint(end - direction * 0.1))
            XCTAssertNotEqual(back, previous)
            model.endAdjustingIntensity()
            XCTAssertFalse(model.isAdjustingIntensity)
        }
    }

    func testSettingsSubmenuRevealsSliderAndBothTogglesAndPinsHoverWhileDragging() {
        let model = SessionWheelModel()
        let slot = SessionWheelShortcut.settings.rawValue
        model.hover(at: geometry.position(slot: slot, radius: 119))
        XCTAssertTrue(model.isHoveringSettings)
        XCTAssertEqual(model.submenuSlot, slot)
        model.hover(at: geometry.position(slot: slot, radius: geometry.wheelRadius + 4))
        XCTAssertEqual(model.submenuSlot, slot, "Hover continues across the gap")
        XCTAssertNil(model.hoveredSettingsControl)
        for (index, control) in [(0, SessionWheelSettingsControl.intensity), (1, .intensity), (2, .intensity),
                                 (3, .intensity), (4, .keepAwake), (5, .autoPlay)] {
            model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius,
                                              offset: geometry.actionOffset(index, subdivisions: 6)))
            XCTAssertEqual(model.hoveredSettingsControl, control)
            XCTAssertNil(model.hoveredNoteAction)
            XCTAssertNil(model.hoveredSessionItem)
        }
        let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                       outerRadius: geometry.actionOuterRadius, subdivision: 0, span: 2)
        let bounds = CGRect(origin: .zero, size: CGSize(width: 528, height: 528))
        for index in [0, 1] {
            XCTAssertTrue(shape.path(in: bounds).contains(
                geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(index))))
        }
        XCTAssertTrue(shape.path(in: bounds).contains(
            geometry.position(slot: slot, radius: geometry.actionRadius, offset: -geometry.sliceAngle / 6)),
            "One continuous slider across the subdivision boundary")
        XCTAssertFalse(shape.path(in: bounds).contains(
            geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(2))))

        model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(0)))
        model.adjustIntensity(to: geometry.position(slot: slot, radius: geometry.actionRadius))
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.refresh(sessions: [session("a")])
        XCTAssertEqual(model.submenuSlot, slot, "A drag keeps the submenu open wherever the pointer goes")
        model.endAdjustingIntensity()
        model.hover(at: geometry.position(slot: 0, radius: 119))
        XCTAssertEqual(model.hoveredSession?.id, "a")
        XCTAssertNil(model.hoveredSettingsControl)
    }

    /// Submenu controls name themselves in the notch, so every caption is a
    /// valid one-to-three-word hover descriptor and no caption is drawn on the wheel.
    func testSubmenuControlCaptionsAreShortNotchDescriptors() throws {
        var captions = SessionWheelSettingsControl.allCases.map(\.caption)
        for phase in [MeetingNoteCoordinatorPhase.idle, .recording, .paused] {
            captions += SessionWheelNoteAction.allCases.map { $0.caption(for: phase) }
        }
        captions += SessionWheelTabControl.allCases.map(\.caption)
        for tab in tabs(9, active: 8, off: [3]) { captions.append(tab.caption) }
        captions += ["Only live tab", "Nine tabs open", "Tab starting", "Finish notes first", "No session"]
        for caption in captions {
            XCTAssertTrue(NotchHoverDescriptor.isValid(caption), caption)
        }
        XCTAssertEqual(SessionWheelTabControl.add.caption, "Add tab")
        XCTAssertEqual(SessionWheelTabControl.remove.caption, "Remove tab")
        XCTAssertEqual(tabs(2, active: 1)[1].caption, "PM 2 active")
        XCTAssertEqual(tabs(2, off: [1])[1].caption, "PM 2 off")
        XCTAssertEqual(SessionWheelNoteAction.pause.caption(for: .recording), "Pause")
        XCTAssertEqual(SessionWheelSettingsControl.keepAwake.caption, "Keep awake")

        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "tests/RelayRunnerTests/SessionWheelTests.swift",
                                  with: "Sources/relay-runner/Board/SessionWheelView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("hoveredControlCaption"), "No caption is drawn under a segment title")
        XCTAssertFalse(source.contains("graphicalTooltip"), "The wheel describes controls through the notch")
        XCTAssertFalse(source.contains(".notchHint("),
                       "Controls overlap across the whole wheel, so the model names the hovered target")
    }

    /// The notch names exactly the segment or outer control under the pointer,
    /// never whichever overlapping control view happens to be on top.
    func testHoverDescriptorFollowsTheModelsHoverTarget() {
        let model = SessionWheelModel()
        func hint(slot: Int, radius: CGFloat = 119, offset: CGFloat = 0) -> String? {
            let point = geometry.position(slot: slot, radius: radius, offset: offset)
            model.hover(at: point)
            return model.hoverDescriptor(at: point)
        }
        XCTAssertEqual(hint(slot: 0), "Start session")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.history.rawValue), "History")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.workspace.rawValue), "Workspace")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.noteTaker.rawValue), "Notetaker")
        let settings = SessionWheelShortcut.settings.rawValue
        XCTAssertEqual(hint(slot: settings), "Settings", "The parent alone, not its Autoplay control")
        XCTAssertEqual(hint(slot: settings, radius: geometry.wheelRadius + 4), "Settings", "The gap keeps the parent")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(5, subdivisions: 6)), "Autoplay off")
        model.autoPlay = true
        XCTAssertEqual(model.hoverDescriptor(at: geometry.position(slot: settings, radius: geometry.actionRadius,
                                                                   offset: geometry.actionOffset(5, subdivisions: 6))),
                       "Autoplay on")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(4, subdivisions: 6)), "Keep awake off")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(0, subdivisions: 6)), "Particles 60%")
        model.particleFieldEnabled = false
        XCTAssertEqual(model.hoverDescriptor(at: geometry.position(slot: settings, radius: geometry.actionRadius)),
                       "Particles off")

        let noteTaker = SessionWheelShortcut.noteTaker.rawValue
        _ = hint(slot: noteTaker)
        XCTAssertEqual(hint(slot: noteTaker, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(SessionWheelNoteAction.cancel.rawValue)), "Discard")
        XCTAssertEqual(hint(slot: noteTaker, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(SessionWheelNoteAction.recording.rawValue)), "Start note")

        model.startUnavailableReason = "Finish notes first"
        XCTAssertEqual(hint(slot: 0), "Finish notes first")
        model.startUnavailableReason = nil
        model.refresh(sessions: [.init(id: "a", name: "general")])
        model.tabs = tabs(2)
        XCTAssertEqual(hint(slot: 0), "Terminal")
        let first = geometry.sessionItemArc(0, items: 5)
        XCTAssertEqual(hint(slot: 0, radius: geometry.actionRadius, offset: first.start + first.width / 2), "PM 1 active")
        let add = geometry.sessionItemArc(2, items: 5)
        XCTAssertEqual(hint(slot: 0, radius: geometry.actionRadius, offset: add.start + add.width / 2), "Add tab")

        model.hover(at: geometry.center)
        XCTAssertEqual(model.hoverDescriptor(at: geometry.center), "Close")
        model.notice = "Couldn't start session"
        XCTAssertEqual(model.hoverDescriptor(at: geometry.center), "Couldn't start session")
        let outside = CGPoint(x: -30, y: -30)
        model.hover(at: outside)
        XCTAssertNil(model.hoverDescriptor(at: outside))
        for hint in ["Start session", "Finish notes first", "Autoplay off", "Keep awake off", "Particles 60%"] {
            XCTAssertTrue(NotchHoverDescriptor.isValid(hint), hint)
        }
    }

    func testSettingsControlsHaveSeparateHitTargetsWithinTheSameArc() {
        let bounds = CGRect(origin: .zero, size: CGSize(width: 528, height: 528))
        let controls = SessionWheelSettingsControl.allCases
        let paths = controls.map {
            SessionWheelSector(slot: 2, innerRadius: geometry.actionInnerRadius,
                               outerRadius: geometry.actionOuterRadius, subdivision: $0.rawValue,
                               span: $0.span, subdivisions: 6).path(in: bounds)
        }
        // Every point belongs to at most one control, and no hit target escapes Settings.
        for degrees in 0..<360 {
            let angle = CGFloat(degrees) * .pi / 180
            for radius in [geometry.actionInnerRadius + 7, geometry.actionRadius, geometry.actionOuterRadius - 7] {
                let point = arcPoint(angle, radius: radius)
                let hits = paths.filter { $0.contains(point) }.count
                XCTAssertLessThanOrEqual(hits, 1)
                if hits > 0 { XCTAssertEqual(geometry.slot(at: point), 2) }
            }
        }
        for (index, control) in controls.enumerated() {
            let offset = control == .intensity ? -geometry.sliceAngle / 6
                : geometry.actionOffset(control.rawValue, subdivisions: 6)
            let point = geometry.position(slot: 2, radius: geometry.actionRadius, offset: offset)
            XCTAssertTrue(paths[index].contains(point), "\(control) has a reachable centre")
        }
        // The split between the two toggles remains a gap, not an accidental click.
        XCTAssertTrue(paths.allSatisfy { !$0.contains(arcPoint(geometry.sliceAngle * (2 + 5.0 / 6))) })
    }

    @MainActor
    func testIntensityDragPreviewsLiveCommitsOnceAndKeepsTheWheelOpen() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var saved = 0.6
        var previews: [Double] = []
        var commits: [Double] = []
        var shortcuts: [SessionWheelShortcut] = []
        controller.refresh = { model in
            if !model.isAdjustingIntensity { model.particleIntensity = saved }
        }
        controller.previewIntensity = { previews.append($0) }
        controller.commitIntensity = { commits.append($0); saved = $0 }
        controller.openShortcut = { shortcuts.append($0) }
        controller.toggle()
        let intensity = SessionWheelIntensity.self
        controller.model.hover(at: geometry.position(slot: 2, radius: 119))
        for step in 0...40 {
            controller.adjustIntensity(to: arcPoint(intensity.minAngle + 0.2 - CGFloat(step) * 0.02))
            controller.refresh?(controller.model)
        }
        XCTAssertEqual(previews.last, 1.0)
        XCTAssertEqual(previews, previews.sorted(), "Preview follows the drag")
        XCTAssertEqual(Set(previews).count, previews.count, "Only changed values are previewed")
        XCTAssertTrue(commits.isEmpty, "Nothing persists mid-drag")
        XCTAssertTrue(pulses.isEmpty, "No haptic spam while dragging")
        controller.finishIntensity()
        XCTAssertEqual(commits, [1.0])
        XCTAssertEqual(pulses, [.generic])
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.submenuSlot, 2)

        controller.stepIntensity(1)
        XCTAssertEqual(commits, [1.0], "Clamped at the top")
        controller.stepIntensity(-1)
        XCTAssertEqual(commits, [1.0, 0.95])
        controller.model.particleFieldEnabled = false
        controller.adjustIntensity(to: arcPoint(intensity.minAngle))
        controller.stepIntensity(-1)
        XCTAssertEqual(commits, [1.0, 0.95], "Disabled with the particle field off")

        controller.selectSlot(SessionWheelShortcut.settings.rawValue, fromPointer: false)
        XCTAssertEqual(shortcuts, [.settings], "The main Settings wedge still opens Settings")

        controller.model.particleFieldEnabled = true
        controller.adjustIntensity(to: arcPoint(intensity.minAngle))
        controller.dismiss()
        XCTAssertEqual(commits.last, 0.1, "Dismissal mid-drag still saves")
        XCTAssertFalse(controller.model.isAdjustingIntensity)
        XCTAssertEqual(pulses.count, 3, "Dismissal does not pulse")
    }

    @MainActor
    func testSliderHoverAndDragPreviewParticlesUntilReleasedOrDismissed() {
        _ = NSApplication.shared
        let controller = SessionWheelController(haptics: .init(perform: { _ in }))
        defer { controller.dismiss() }
        var previews: [Bool] = []
        var values: [Double] = []
        controller.previewParticles = { previews.append($0) }
        controller.previewIntensity = { values.append($0) }
        controller.toggle()
        let slot = SessionWheelShortcut.settings.rawValue
        let slider = geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(0))
        let keepAwake = geometry.position(slot: slot, radius: geometry.actionRadius,
                                         offset: geometry.actionOffset(4, subdivisions: 6))
        let session = geometry.position(slot: 0, radius: 119)
        func hover(_ point: CGPoint?) {
            if let point { controller.model.hover(at: point) } else { controller.model.clearHover() }
            controller.hoverFeedback(at: point, target: nil)
        }
        // The pointer reaches the outer arc through the Settings wedge.
        func enterSlider() {
            hover(geometry.position(slot: slot, radius: 119))
            hover(slider)
        }

        hover(geometry.position(slot: slot, radius: 119))
        XCTAssertEqual(previews, [], "Opening Settings alone does not preview")
        hover(slider)
        hover(slider)
        hover(geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(1)))
        XCTAssertEqual(previews, [true], "Repeated hover ticks never restart the entrance")
        XCTAssertTrue(values.isEmpty, "Hover previews the current intensity")
        hover(keepAwake)
        XCTAssertEqual(previews, [true, false])

        enterSlider()
        controller.adjustIntensity(to: slider)
        controller.adjustIntensity(to: session)
        XCTAssertEqual(previews, [true, false, true], "Dragging off the arc keeps the preview")
        XCTAssertFalse(values.isEmpty, "Dragging updates the previewed intensity live")
        controller.finishIntensity(at: session)
        XCTAssertEqual(previews, [true, false, true, false], "Releasing off the slider ends it")
        XCTAssertNil(controller.model.submenuSlot)

        enterSlider()
        controller.adjustIntensity(to: slider)
        controller.finishIntensity(at: slider)
        XCTAssertEqual(previews.last, true, "Releasing on the slider keeps hovering it")
        hover(nil)
        XCTAssertEqual(previews.last, false)

        controller.model.particleFieldEnabled = false
        enterSlider()
        XCTAssertEqual(previews.last, false, "No preview while the particle field is off")
        controller.model.particleFieldEnabled = true
        hover(slider)
        XCTAssertEqual(previews.last, true)
        let count = previews.count
        controller.dismiss()
        XCTAssertEqual(previews.count, count + 1)
        XCTAssertEqual(previews.last, false, "Dismissal ends the preview")
        XCTAssertFalse(controller.isPreviewingParticles)
    }

    @MainActor
    func testKeepAwakeControlKeepsTheWheelOpenAndIgnoresPendingChanges() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var state = KeepAwakeState.off
        var calls = 0
        controller.refresh = { model in model.keepAwake = state }
        controller.keepAwakeAction = {
            calls += 1
            state = state.isOn ? .off : .enabling
            return true
        }
        controller.toggle()
        controller.model.hover(at: geometry.position(slot: 2, radius: 119))
        controller.performKeepAwake()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.model.keepAwake, .enabling)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.submenuSlot, 2)
        controller.performKeepAwake()
        XCTAssertEqual(calls, 1, "Pending approval ignores repeat clicks")
        state = .on(ownsSleepSetting: true)
        controller.refresh?(controller.model)
        controller.performKeepAwake()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.model.keepAwake, .off)
        XCTAssertEqual(pulses, [.generic, .generic])
        controller.keepAwakeAction = { false }
        controller.performKeepAwake()
        XCTAssertEqual(controller.model.notice, "Keep Awake unavailable")
        XCTAssertEqual(pulses.count, 2)
    }

    @MainActor
    func testAutoPlayToggleRefreshesWithoutClosingAndIsIndependentOfKeepAwake() {
        _ = NSApplication.shared
        var pulses: [NSHapticFeedbackManager.FeedbackPattern] = []
        let controller = SessionWheelController(haptics: .init(perform: { pulses.append($0) }))
        defer { controller.dismiss() }
        var autoPlay = false
        var calls = 0
        controller.refresh = { model in model.autoPlay = autoPlay }
        controller.autoPlayAction = {
            calls += 1
            autoPlay.toggle()
            return true
        }
        controller.performAutoPlay()
        XCTAssertEqual(calls, 0, "A closed wheel cannot change the setting")
        controller.toggle()
        controller.model.hover(at: geometry.position(slot: 2, radius: 119))
        controller.model.keepAwake = .enabling
        controller.performAutoPlay()
        XCTAssertTrue(controller.model.autoPlay)
        XCTAssertEqual(controller.model.keepAwake, .enabling)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.submenuSlot, 2)
        controller.performAutoPlay()
        XCTAssertFalse(controller.model.autoPlay)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(pulses, [.generic, .generic])
        autoPlay = true // The main Settings page can change the same value.
        controller.refresh?(controller.model)
        XCTAssertTrue(controller.model.autoPlay)
        controller.autoPlayAction = { false }
        controller.performAutoPlay()
        XCTAssertEqual(controller.model.notice, "Voice auto-play unavailable")
        XCTAssertEqual(pulses.count, 2, "Rejected actions do not confirm with a haptic")
    }

    func testKeepAwakeGlyphUsesAFilledBoltAndSwapsOnlyForPendingApprovalAndFailures() {
        typealias Look = SessionWheelKeepAwakeGlyph.Look
        let off = Look(.off)
        let on = Look(.on(ownsSleepSetting: true))
        XCTAssertEqual(off.symbol, "bolt.fill")
        XCTAssertEqual(on.symbol, "bolt.fill")
        XCTAssertEqual(Look(.on(ownsSleepSetting: false)), on)
        XCTAssertEqual(off.tint, .off)
        XCTAssertEqual(on.tint, .on)
        XCTAssertEqual(on.color, ProgramBoardStyle.activeTrayOrange)
        XCTAssertEqual(off.color, .white)
        XCTAssertFalse(off.swapsSymbol(to: on), "Off and on only retint the same bolt")
        XCTAssertFalse(on.swapsSymbol(to: off))
        for state in [KeepAwakeState.enabling, .disabling, .awaitingApproval, .failed("x"), .restoreNeeded("x")] {
            XCTAssertTrue(off.swapsSymbol(to: Look(state)), "\(state)")
            XCTAssertTrue(Look(state).swapsSymbol(to: on), "\(state)")
            XCTAssertNotEqual(Look(state).tint, .on, "Only a confirmed on state is orange")
        }
        XCTAssertEqual(Look(.enabling), Look(.disabling))
        XCTAssertNotEqual(Look(.awaitingApproval).symbol, Look(.enabling).symbol, "Approval is distinct from a pending change")
        XCTAssertEqual(Look(.restoreNeeded("x")).tint, .alert)
        XCTAssertNotEqual(Look(.failed("x")).symbol, Look(.restoreNeeded("x")).symbol)
        for state in [KeepAwakeState.off, .enabling, .awaitingApproval, .on(ownsSleepSetting: true), .failed("x"), .restoreNeeded("x")] {
            XCTAssertNotNil(NSImage(systemSymbolName: Look(state).symbol, accessibilityDescription: nil), "\(state)")
        }

        // A swap runs its exit, then its entrance, within one change duration (≈225 ms).
        let swap = SessionWheelKeepAwakeGlyph.exitDuration + SessionWheelKeepAwakeGlyph.enterDuration
        XCTAssertEqual(swap, RelayMotion.changeDuration, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(swap, 0.15)
        XCTAssertLessThanOrEqual(swap, 0.23)
        XCTAssertLessThan(SessionWheelKeepAwakeGlyph.exitDuration, SessionWheelKeepAwakeGlyph.enterDuration,
                          "Exits are quicker than entrances")
        let style = SessionWheelKeepAwakeGlyph.hiddenStyle
        XCTAssertGreaterThan(style.hiddenScale, 0.5, "Never animates from nothing")
        XCTAssertEqual(style.scale(hidden: true, reduceMotion: true), 1, "Reduce Motion fades without scaling")
        XCTAssertEqual(style.blur(hidden: true, reduceMotion: true), 0, "Reduce Motion fades without blur")
        XCTAssertEqual(style.scale(hidden: false, reduceMotion: false), 1)
        XCTAssertEqual(style.blur(hidden: false, reduceMotion: false), 0)
    }

    /// Set RELAY_WHEEL_RENDER_DIR to export the actual SwiftUI view for visual QA.
    @MainActor
    func testWheelRendering() throws {
        let model = SessionWheelModel()
        model.refresh(sessions: [.init(id: "pm", name: "PM 1", unreadCount: 2, isFocused: true)])
        model.tabs = tabs(1)
        let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performTabItem: { _ in },
                                    selectCenter: {}, dismiss: {})
        for state in ["sessions", "session-notice", "controls", "tabs-1", "tabs-3", "tabs-4", "tabs-6",
                      "tabs-9", "tabs-9-add-hover", "tabs-off",
                      "shortcuts-empty", "start-unavailable", "notes-idle", "notes-recording", "notes-paused", "notes-saving",
                      "overflow-sessions",
                      "settings-min", "settings-max", "settings-keep-awake-off", "settings-keep-awake-on",
                      "settings-keep-awake-off-idle", "settings-keep-awake-on-idle",
                      "settings-auto-play-off", "settings-auto-play-on", "settings-auto-play-on-idle",
                      "settings-keep-awake-pending", "settings-keep-awake-approval", "settings-keep-awake-failed",
                      "settings-restore", "settings-particles-off", "settings-dragging"]
            + geometry.sessionSlots.map({ "contour-\($0)" }) {
            switch state {
            case "session-notice": model.notice = "Session could not start"
            case "controls":
                model.notice = nil
                model.hover(at: geometry.position(slot: 0, radius: 119))
            case "tabs-1", "tabs-3", "tabs-4", "tabs-6", "tabs-9", "tabs-9-add-hover", "tabs-off":
                // RR-469: the session submenu with that many PM tabs.
                let count = state == "tabs-off" ? 3 : Int(state.split(separator: "-")[1]) ?? 1
                model.reset(at: geometry.center)
                model.refresh(sessions: [.init(id: "pm", name: "PM 1", isFocused: true)])
                model.tabs = tabs(count, active: min(1, count - 1), off: state == "tabs-off" ? [2] : [])
                model.addTabUnavailableReason = count >= 9 ? "Nine tabs open" : nil
                model.hover(at: geometry.position(slot: 0, radius: 119))
                model.hover(at: itemPoint(state == "tabs-9-add-hover" ? count : 0, of: count + 3))
            case "shortcuts-empty":
                model.reset(at: geometry.center)
                model.refresh(sessions: [])
                model.startUnavailableReason = nil
            case "start-unavailable": model.startUnavailableReason = "Finish taking notes first"
            case "notes-idle", "notes-recording", "notes-paused", "notes-saving":
                model.notePhase = state == "notes-recording" ? .recording
                    : state == "notes-paused" ? .paused
                    : state == "notes-saving" ? .transcribing : .idle
                model.hover(at: geometry.position(slot: SessionWheelShortcut.noteTaker.rawValue, radius: 119))
            case "settings-min", "settings-max", "settings-keep-awake-off", "settings-keep-awake-on",
                 "settings-keep-awake-off-idle", "settings-keep-awake-on-idle",
                 "settings-auto-play-off", "settings-auto-play-on", "settings-auto-play-on-idle",
                 "settings-keep-awake-pending", "settings-keep-awake-approval", "settings-keep-awake-failed",
                 "settings-restore", "settings-particles-off", "settings-dragging":
                model.reset(at: geometry.center)
                model.notePhase = .idle
                model.particleFieldEnabled = state != "settings-particles-off"
                model.particleIntensity = state == "settings-min" ? 0.1 : state == "settings-max" ? 1.0 : 0.6
                model.autoPlay = state.hasPrefix("settings-auto-play-on")
                model.keepAwake = state.hasPrefix("settings-keep-awake-on") ? .on(ownsSleepSetting: true)
                    : state == "settings-keep-awake-pending" ? .enabling
                    : state == "settings-keep-awake-approval" ? .awaitingApproval
                    : state == "settings-keep-awake-failed" ? .failed(KeepAwakePowerHelper.missingMessage)
                    : state == "settings-restore" ? .restoreNeeded("Restore") : .off
                let slot = SessionWheelShortcut.settings.rawValue
                model.hover(at: geometry.position(slot: slot, radius: 119))
                let hoversKeepAwake = ["settings-keep-awake-off", "settings-keep-awake-on"].contains(state)
                let hoversAutoPlay = ["settings-auto-play-off", "settings-auto-play-on"].contains(state)
                model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius,
                                                  offset: geometry.actionOffset(hoversKeepAwake ? 4 : hoversAutoPlay ? 5 : 0,
                                                                                subdivisions: 6)))
                if state == "settings-dragging" {
                    model.adjustIntensity(to: geometry.position(slot: slot, radius: geometry.actionRadius,
                                                                offset: -geometry.sliceAngle / 6))
                    model.endAdjustingIntensity()
                }
            case "overflow-sessions":
                model.reset(at: geometry.center)
                model.notePhase = .idle
                model.startUnavailableReason = nil
                model.refresh(sessions: (0..<4).map { .init(id: "\($0)", name: "Project \($0 + 1)") })
            default:
                if state.hasPrefix("contour-"), let slot = Int(state.suffix(1)) {
                    model.reset(at: geometry.center)
                    model.startUnavailableReason = nil
                    model.refresh(sessions: (0..<geometry.sessionSlots.count).map {
                        .init(id: "\($0)", name: "Project \($0 + 1)")
                    })
                    model.tabs = tabs(2)
                    model.hover(at: geometry.position(slot: slot, radius: 119))
                }
            }
            let renderer = ImageRenderer(content: view
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .background(Color(red: 0.06, green: 0.07, blue: 0.09)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 1056)
            XCTAssertEqual(image.height, 1056)
            if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("\(state).png"))
            }
        }
    }
}
