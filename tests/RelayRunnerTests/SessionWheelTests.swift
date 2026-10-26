import SwiftUI
import XCTest
@testable import relay_runner

final class SessionWheelTests: XCTestCase {
    func testWorkspaceActionTracksVisibilityAndDoesNotChangeWithSessionHover() {
        let model = SessionWheelModel()
        XCTAssertEqual(model.workspaceActionTitle, "Open workspace")
        model.refresh(sessions: [.init(id: "relay", name: "Relay Runner")])
        model.hover(at: SessionWheelGeometry.position(slot: 0, radius: 119))
        XCTAssertEqual(model.workspaceActionTitle, "Open workspace")
        model.isWorkspaceVisible = true
        XCTAssertEqual(model.workspaceActionTitle, "Close workspace")
    }

    private let geometry = SessionWheelGeometry.self
    private func makeController() -> SessionWheelController {
        SessionWheelController(haptics: .init(perform: { _ in }))
    }
    private func session(_ id: String) -> SessionWheelSession { .init(id: id, name: id) }
    private func projects(_ count: Int) -> [SessionWheelProject] {
        (0..<count).map { .init(id: "\($0)", name: "Project \($0)", path: "/projects/\($0)") }
    }

    func testSessionPositionsSurviveRefreshAndAnEmptySlotIsReused() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a"), session("b"), session("c")])
        model.hover(at: geometry.position(slot: 5, radius: 119))
        model.refresh(sessions: [session("c"), session("b")])
        XCTAssertNil(model.slots[0])
        XCTAssertEqual(model.slots[1]?.id, "b")
        XCTAssertEqual(model.slots[5]?.id, "c")
        XCTAssertEqual(model.hoveredSession?.id, "c")
        model.refresh(sessions: [session("d"), session("c"), session("b")])
        XCTAssertEqual(model.slots[0]?.id, "d")
        XCTAssertEqual(model.slots[5]?.id, "c")
        XCTAssertEqual(model.slots.count, 6)
    }

    func testEverySessionHasReachableOuterActionsAcrossTheRadialGap() {
        for slot in 0..<geometry.slotCount {
            let model = SessionWheelModel()
            model.refresh(sessions: (0..<6).map { session("\($0)") })
            model.showAllSessions(at: geometry.center)
            model.hover(at: geometry.position(slot: slot, radius: 119))
            XCTAssertEqual(model.hoveredSlot, slot)
            model.hover(at: geometry.position(slot: slot, radius: (geometry.wheelRadius + geometry.actionInnerRadius) / 2))
            XCTAssertEqual(model.hoveredSession?.id, "\(slot)")
            XCTAssertNil(model.hoveredAction)
            for action in SessionWheelAction.allCases {
                let point = geometry.position(slot: slot, radius: geometry.actionRadius,
                                              offset: geometry.actionOffset(action))
                model.hover(at: point)
                XCTAssertEqual(model.hoveredSlot, slot)
                XCTAssertEqual(model.hoveredAction, action)
                let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius, subdivision: action.rawValue)
                XCTAssertTrue(shape.path(in: CGRect(origin: .zero, size: CGSize(width: 528, height: 528))).contains(point))
            }
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

    func testRootReservesTopThreeSlotsForSessionsAndBottomThreeForShortcuts() {
        let model = SessionWheelModel()
        XCTAssertEqual((0..<6).filter { model.shortcut(at: $0) == nil }, [0, 1, 5])
        XCTAssertEqual([4, 3, 2].compactMap { model.shortcut(at: $0) }, [.workspace, .noteTaker, .settings])
        let positions = [4, 3, 2].map { geometry.position(slot: $0, radius: 119) }
        XCTAssertTrue(positions.allSatisfy { $0.y > geometry.center.y })
        XCTAssertLessThan(positions[0].x, positions[1].x)
        XCTAssertLessThan(positions[1].x, positions[2].x)
        model.refresh(sessions: [session("a"), session("b"), session("c")])
        XCTAssertEqual([0, 1, 5].compactMap { model.slots[$0]?.id }, ["a", "b", "c"])
        XCTAssertTrue([2, 3, 4].allSatisfy { model.slots[$0] == nil })
        model.showProjects(at: geometry.center)
        XCTAssertTrue((0..<6).allSatisfy { model.shortcut(at: $0) == nil })
    }

    func testOverflowSessionsRemainReachableAndReturnToFreeTopSlots() {
        let model = SessionWheelModel()
        model.refresh(sessions: ["a", "b", "c", "d"].map(session))
        XCTAssertTrue(model.isMoreSessionsSlot(5))
        XCTAssertNil(model.slots[5])
        model.showAllSessions(at: geometry.center)
        XCTAssertEqual(model.slots.compactMap { $0?.id }, ["a", "b", "c", "d"])
        XCTAssertTrue(model.isNested)
        model.hover(at: geometry.position(slot: 3, radius: 119))
        XCTAssertEqual(model.hoveredSession?.id, "d")
        XCTAssertFalse(model.isHoveringNoteTaker)
        XCTAssertTrue(model.back(at: geometry.center))
        model.refresh(sessions: ["a", "b", "d"].map(session))
        XCTAssertFalse(model.hasMoreSessions)
        XCTAssertEqual(model.slots[5]?.id, "d")
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
            XCTAssertNil(model.hoveredAction)
            XCTAssertEqual(model.submenuSlot, slot)
        }
        model.showProjects(at: geometry.center)
        model.hover(at: geometry.position(slot: slot, radius: 119))
        XCTAssertNil(model.submenuSlot)
        XCTAssertNil(model.hoveredNoteAction)
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
        controller.refresh = { model, _ in model.notePhase = phase }
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
        for slot in [4, 3, 2] {
            controller.selectSlot(slot, fromPointer: false)
            XCTAssertTrue(controller.isVisible)
            XCTAssertFalse(controller.model.pickingProject)
        }
        XCTAssertEqual(shortcuts, [.workspace, .noteTaker, .settings])
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
        XCTAssertEqual(shortcuts.count, 3)
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

        for shortcut in [SessionWheelShortcut.noteTaker, .settings] {
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

    @MainActor
    func testOverflowNavigationPreservesSessionsAndWheelVisibility() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model, _ in model.refresh(sessions: ["a", "b", "c", "d"].map(self.session)) }
        var focused: String?
        controller.focusSession = { focused = $0 }
        controller.openShortcut = { _ in XCTFail("The nested session slot must not open a shortcut") }
        controller.toggle()
        controller.selectSlot(5, fromPointer: false)
        XCTAssertTrue(controller.model.showingAllSessions)
        controller.selectSlot(3, fromPointer: false)
        XCTAssertEqual(focused, "d")
        XCTAssertTrue(controller.isVisible)
        controller.selectCenter()
        XCTAssertFalse(controller.model.isNested)
        XCTAssertTrue(controller.isVisible)
    }

    func testContourLabelsStayUprightAndFitInsideEveryThinActionSegment() {
        let bounds = CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter))
        for slot in 0..<geometry.slotCount {
            for action in SessionWheelAction.allCases {
                let rotation = geometry.actionLabelRotation(slot: slot, action: action)
                let center = geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(action))
                XCTAssertLessThanOrEqual(abs(rotation), .pi / 2, "Labels must never turn upside down")
                let radialAngle = CGFloat(slot) * geometry.sliceAngle + geometry.actionOffset(action)
                XCTAssertEqual(sin(radialAngle) * cos(rotation) - cos(radialAngle) * sin(rotation), 0, accuracy: 0.0001)
                let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius, subdivision: action.rawValue)
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
        XCTAssertNil(model.hoveredAction)
    }

    func testStoppedSessionLosesItsActionsImmediately() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius))
        XCTAssertEqual(model.hoveredAction, .recording)
        model.refresh(sessions: [])
        XCTAssertNil(model.hoveredSession)
        XCTAssertNil(model.hoveredAction)
    }

    func testReplacementSessionDoesNotInheritTheStoppedSessionsHoveredAction() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius, offset: geometry.actionOffset(.stop)))
        XCTAssertEqual(model.hoveredAction, .stop)
        model.refresh(sessions: [session("b")])
        XCTAssertEqual(model.slots[0]?.id, "b")
        XCTAssertNil(model.hoveredSlot)
        XCTAssertNil(model.hoveredAction)
    }

    func testProjectPickerRequiresFreshMovementAndBackDoesNotCloseTheWheel() {
        let model = SessionWheelModel()
        model.projects = projects(2)
        let entry = geometry.position(slot: 0, radius: 119)
        model.hover(at: entry)
        model.showProjects(at: entry)
        model.hover(at: entry)
        XCTAssertTrue(model.pickingProject)
        XCTAssertNil(model.hoveredSlot)
        model.hover(at: CGPoint(x: entry.x + 10, y: entry.y))
        XCTAssertEqual(model.hoveredSlot, 0)
        XCTAssertNil(model.hoveredSession)
        XCTAssertTrue(model.back(at: entry))
        XCTAssertFalse(model.pickingProject)
        XCTAssertNil(model.hoveredSlot)
        XCTAssertFalse(model.back(at: entry))
    }

    func testProjectPaginationReachesEveryProjectAndClampsWhenListShrinks() {
        let model = SessionWheelModel()
        model.projects = projects(13)
        model.showProjects(at: geometry.center)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertEqual(model.visibleProjects.map(\.id), (0..<5).map(String.init))
        XCTAssertTrue(model.isMoreProjectsSlot(5))
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.visibleProjects.map(\.id), (5..<10).map(String.init))
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.visibleProjects.map(\.id), ["10", "11", "12"])
        XCTAssertFalse(model.isMoreProjectsSlot(5))
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.projectPage, 2)
        XCTAssertTrue(model.back(at: geometry.center))
        XCTAssertEqual(model.projectPage, 1)
        XCTAssertTrue(model.pickingProject)
        model.projects = projects(2)
        model.refresh(sessions: [])
        XCTAssertEqual(model.projectPage, 0)
        model.projects = []
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.projectPage, 0)
        XCTAssertTrue(model.visibleProjects.isEmpty)
    }

    func testProjectWheelsReserveMoreOnlyWhenNeededAndReachEveryProject() {
        for count in 0...31 {
            let model = SessionWheelModel()
            model.projects = projects(count)
            model.showProjects(at: geometry.center)
            var visited: [String] = []
            for page in 0..<model.pageCount {
                visited += model.visibleProjects.map(\.id)
                XCTAssertEqual(model.visibleProjects.count + (model.hasMoreProjects ? 1 : 0),
                               min(geometry.slotCount, count - page * 5))
                model.turnPage(1, at: geometry.center)
            }
            XCTAssertEqual(visited, (0..<count).map(String.init))
            for _ in 0..<model.pageCount { XCTAssertTrue(model.back(at: geometry.center)) }
            XCTAssertFalse(model.pickingProject)
        }
    }

    @MainActor
    func testSessionCenterTogglesWorkspaceWithoutDismissingTheWheel() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var workspaceVisible = false
        var toggleCount = 0
        controller.refresh = { model, _ in model.isWorkspaceVisible = workspaceVisible }
        controller.toggleWorkspace = {
            XCTAssertTrue(controller.isVisible)
            workspaceVisible.toggle()
            toggleCount += 1
        }

        controller.toggle()
        controller.selectCenter()
        XCTAssertTrue(workspaceVisible)
        XCTAssertTrue(controller.model.isWorkspaceVisible, "Update the glyph immediately after opening Workspace")
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(toggleCount, 1)
        controller.selectCenter()
        XCTAssertFalse(workspaceVisible, "An already open Workspace should close")
        XCTAssertFalse(controller.model.isWorkspaceVisible)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(toggleCount, 2)
        controller.dismiss()
        controller.selectCenter()
        XCTAssertEqual(toggleCount, 2, "A dismissed center must not toggle Workspace")
    }

    @MainActor
    func testSessionSelectionKeepsWheelOpenAndRefreshesFocus() {
        _ = NSApplication.shared
        for isFocused in [false, true] {
            for fromPointer in [false, true] {
                let controller = makeController()
                defer { controller.dismiss() }
                var focused = isFocused
                controller.refresh = { model, _ in
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

    @MainActor
    func testProjectCenterGoesBackOnePageWithoutTogglingWorkspace() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model, _ in model.projects = self.projects(7) }
        controller.toggleWorkspace = { XCTFail("Back must not toggle Workspace") }
        controller.toggle()
        controller.selectSlot(0, fromPointer: false)
        controller.selectSlot(5, fromPointer: false)
        XCTAssertEqual(controller.model.projectPage, 1)

        controller.selectCenter()
        XCTAssertEqual(controller.model.projectPage, 0)
        XCTAssertTrue(controller.model.pickingProject)
        XCTAssertTrue(controller.isVisible)
        controller.selectCenter()
        XCTAssertFalse(controller.model.pickingProject)
        XCTAssertTrue(controller.isVisible)
    }

    @MainActor
    func testEscapeNavigatesBackButOnlyTheToggleClosesTheRootWheel() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model, _ in model.projects = self.projects(7) }
        controller.toggle()
        controller.selectSlot(0, fromPointer: false)
        controller.selectSlot(5, fromPointer: false)
        controller.back()
        XCTAssertEqual(controller.model.projectPage, 0)
        XCTAssertTrue(controller.model.pickingProject)
        controller.back()
        XCTAssertFalse(controller.model.pickingProject)
        controller.back()
        XCTAssertTrue(controller.isVisible)
        controller.toggle()
        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testMoreSegmentNavigatesAtSessionLimitAndStartingAProjectKeepsWheelOpen() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.refresh = { model, _ in model.projects = self.projects(7) }
        var started: String?
        controller.startProject = { started = $0; return true }
        controller.toggle()
        controller.selectSlot(0, fromPointer: false)
        controller.model.startUnavailableReason = "Session limit reached"
        controller.selectSlot(5, fromPointer: false)
        XCTAssertEqual(controller.model.projectPage, 1)
        XCTAssertNil(started)
        controller.model.startUnavailableReason = nil
        controller.selectSlot(1, fromPointer: false)
        XCTAssertEqual(started, projects(7)[6].path)
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.model.pickingProject)
    }

    @MainActor
    func testNewSessionUsesTheChosenEmptySlotAfterProjectPagination() {
        _ = NSApplication.shared
        for slot in geometry.sessionSlots {
            for delayed in [false, true] {
                let controller = makeController()
                defer { controller.dismiss() }
                let project = projects(7)[6]
                let context = AssistantSessionContext(kind: .project, projectID: project.id, repositoryPath: project.path)
                let startedSession = session(context.id)
                var live: [SessionWheelSession] = []
                controller.refresh = { model, _ in
                    model.projects = self.projects(7)
                    model.refresh(sessions: live)
                }
                controller.startProject = { path in
                    XCTAssertEqual(path, project.path)
                    if !delayed { live = [startedSession] }
                    return true
                }
                controller.toggle()
                controller.selectSlot(slot, fromPointer: false)
                controller.selectSlot(5, fromPointer: false)
                controller.selectSlot(1, fromPointer: false)
                XCTAssertFalse(controller.model.pickingProject)
                XCTAssertTrue(controller.isVisible)
                if delayed {
                    controller.model.refresh(sessions: [])
                    controller.model.refresh(sessions: [])
                    live = [startedSession]
                    controller.model.refresh(sessions: live)
                }
                XCTAssertEqual(controller.model.slots[slot]?.id, context.id,
                               "The root slot, not the project page or first free slot, owns the new session")
                XCTAssertEqual(controller.model.slots.compactMap { $0?.id }, [context.id])
                controller.model.refresh(sessions: live)
                XCTAssertEqual(controller.model.slots[slot]?.id, context.id)
            }
        }
    }

    @MainActor
    func testFailedStartDoesNotReuseTheAbandonedSlotAndExistingSessionsStayPut() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        let project = projects(1)[0]
        let context = AssistantSessionContext(kind: .project, projectID: project.id, repositoryPath: project.path)
        var live = [session("existing")]
        controller.refresh = { model, _ in
            model.projects = [project]
            model.refresh(sessions: live)
        }
        controller.startProject = { _ in false }
        controller.toggle()
        controller.selectSlot(5, fromPointer: false)
        controller.selectSlot(0, fromPointer: false)
        XCTAssertTrue(controller.model.pickingProject)
        XCTAssertEqual(controller.model.notice, "Couldn't start session")
        controller.selectCenter()
        controller.selectSlot(1, fromPointer: false)
        controller.startProject = { _ in
            live.append(self.session(context.id))
            return true
        }
        controller.selectSlot(0, fromPointer: false)
        XCTAssertEqual(controller.model.slots[0]?.id, "existing")
        XCTAssertEqual(controller.model.slots[1]?.id, context.id)
        XCTAssertNil(controller.model.slots[5])
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

    func testRecordingCanStopOnlyItsOwnerAndRequiresReadyCaptureToStart() {
        XCTAssertTrue(SessionWheelRecording.canToggle(targetKey: "a", recording: false, recordingKey: "b", ready: true))
        XCTAssertTrue(SessionWheelRecording.canToggle(targetKey: "a", recording: true, recordingKey: "a", ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: "a", recording: true, recordingKey: "b", ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: nil, recording: false, recordingKey: nil, ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: "a", recording: false, recordingKey: nil, ready: false))
    }

    @MainActor
    func testRecordingAndSendingKeepWheelOpenForTheSameSession() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var recording = false
        var targets: [String] = []
        controller.refresh = { model, _ in
            model.refresh(sessions: [.init(id: "a", name: "Project A", isRecording: recording)])
        }
        controller.sessionAction = { id, action in
            XCTAssertEqual(action, .recording)
            targets.append(id)
            recording.toggle()
            return true
        }
        controller.toggle()
        XCTAssertTrue(controller.isVisible)
        controller.model.reset(at: geometry.center)
        controller.model.hover(at: geometry.position(slot: 0, radius: 119))
        controller.model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius))

        controller.performAction("a", .recording)
        XCTAssertTrue(controller.isVisible, "Record must leave the stop/send control reachable")
        XCTAssertEqual(controller.model.hoveredSession?.id, "a")
        XCTAssertEqual(controller.model.hoveredAction, .recording)
        XCTAssertEqual(controller.model.hoveredSession?.isRecording, true)

        controller.performAction("a", .recording)
        XCTAssertEqual(targets, ["a", "a"])
        XCTAssertFalse(recording)
        XCTAssertTrue(controller.isVisible, "Sending must leave the session controls reachable")
        XCTAssertEqual(controller.model.hoveredSession?.isRecording, false)
    }

    @MainActor
    func testPlaybackAndStopSessionKeepWheelOpenAndRefreshItsSlots() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var sessions = [session("a")]
        controller.refresh = { model, _ in model.refresh(sessions: sessions) }
        controller.sessionAction = { _, action in
            if action == .stop { sessions = [] }
            else { sessions[0].playback = .stop }
            return true
        }
        controller.toggle()
        controller.performAction("a", .message)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.slots[0]?.playback, .stop)
        controller.performAction("a", .stop)
        XCTAssertTrue(controller.isVisible)
        XCTAssertNil(controller.model.slots[0])
    }

    @MainActor
    func testStopPlaybackKeepsWheelOpenAndRefreshesThePlaybackControl() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var item = session("a")
        item.playback = .stop
        var acceptsAction = false
        var attempts = 0
        controller.refresh = { model, _ in model.refresh(sessions: [item]) }
        controller.sessionAction = { id, action in
            XCTAssertEqual(id, "a")
            XCTAssertEqual(action, .message)
            attempts += 1
            if acceptsAction { item.playback = .replay }
            return acceptsAction
        }
        controller.toggle()

        controller.performAction("a", .message)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.notice, "Action unavailable")

        acceptsAction = true
        controller.performAction("a", .message)
        XCTAssertTrue(controller.isVisible, "Stopping playback must leave the wheel open")
        XCTAssertEqual(controller.model.slots[0]?.playback, .replay)
        XCTAssertNil(controller.model.notice)
        controller.performAction("a", .message)
        XCTAssertEqual(attempts, 3, "Replay remains reachable after stopping playback")
    }

    func testUnavailableActionsAndRecordingLabelsReflectSessionState() {
        var item = session("a")
        item.canPlay = false
        item.canRecord = false
        XCTAssertFalse(SessionWheelAction.message.isEnabled(for: item))
        XCTAssertFalse(SessionWheelAction.recording.isEnabled(for: item))
        XCTAssertTrue(SessionWheelAction.stop.isEnabled(for: item))
        item.playback = .play
        XCTAssertEqual(SessionWheelAction.message.title(for: item), "Play message")
        XCTAssertEqual(SessionWheelAction.message.symbol(for: item), "play.fill")
        item.playback = .stop
        XCTAssertEqual(SessionWheelAction.message.title(for: item), "Stop playback")
        XCTAssertEqual(SessionWheelAction.message.symbol(for: item), "stop.fill")
        item.playback = .replay
        XCTAssertEqual(SessionWheelAction.message.title(for: item), "Replay message")
        XCTAssertEqual(SessionWheelAction.message.symbol(for: item), "play.fill")
        XCTAssertEqual(SessionWheelAction.recording.symbol(for: item), "mic.fill")
        item.isRecording = true
        XCTAssertEqual(SessionWheelAction.recording.title(for: item), "Stop recording and send message")
        XCTAssertEqual(SessionWheelAction.recording.symbol(for: item), "waveform")
        item.playback = .stop
        XCTAssertEqual(SessionWheelAction.message.symbol(for: item), "stop.fill", "Stopping playback must stay separate from sending the recording")
        XCTAssertEqual(SessionWheelAction.stop.symbol(for: item), "power")
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
    func testWorkspaceGlyphMergesBeforeFormingTheCloseSymbol() throws {
        let dots = NotchContentMotion().renderedGlyphDots(status: .notWorking, now: 0, reduceMotion: true)
        var samples: [CGFloat: NSBitmapImageRep] = [:]
        for progress: CGFloat in [0, 0.3, 0.65, 0.82, 1] {
            let renderer = ImageRenderer(content: SessionWheelWorkspaceGlyphDrawing(
                dots: dots, closeProgress: progress, reduceMotion: false
            ).background(.black))
            renderer.scale = 8
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            samples[progress] = bitmap
        }
        func brightness(_ progress: CGFloat, _ x: Int, _ y: Int) -> CGFloat {
            samples[progress]!.colorAt(x: x * 8, y: y * 8)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        XCTAssertLessThan(brightness(0, 12, 12), 0.1, "The resting dots are separate")
        XCTAssertGreaterThan(brightness(0.65, 12, 12), 0.9, "All dots merge into a single bead")
        XCTAssertLessThan(brightness(0.65, 8, 8), 0.1, "The X only grows after the merge")
        XCTAssertGreaterThan(brightness(1, 8, 8), 0.9)
        XCTAssertGreaterThan(brightness(1, 12, 12), 0.9)
        XCTAssertLessThan(brightness(1, 16, 12), 0.1)

        if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (progress, bitmap) in samples {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("morph-\(progress).png"))
            }
        }
    }

    @MainActor
    func testBackArrowMorphsFromBothStatusAndCloseGlyphs() throws {
        let dots = NotchContentMotion().renderedGlyphDots(status: .notWorking, now: 0, reduceMotion: true)
        var samples: [String: NSBitmapImageRep] = [:]
        for (name, close, back, reduced): (String, CGFloat, CGFloat, Bool) in [
            ("back", 0, 1, false), ("dots-back-bead", 0, 0.65, false),
            ("close-back-bead", 0.5, 0.5, false), ("close-back-reduced", 0.5, 0.5, true)
        ] {
            let renderer = ImageRenderer(content: SessionWheelWorkspaceGlyphDrawing(
                dots: dots, closeProgress: close, backProgress: back, reduceMotion: reduced
            ).background(.black))
            renderer.scale = 8
            samples[name] = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        // Project navigation takes precedence even with Workspace open behind the wheel.
        let renderer = ImageRenderer(content: SessionWheelWorkspaceGlyph(
            isWorkspaceVisible: true, isPickingProject: true, status: .playing
        ).background(.black))
        renderer.scale = 8
        samples["back-with-workspace"] = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func brightness(_ name: String, _ x: Int, _ y: Int) -> CGFloat {
            samples[name]!.colorAt(x: x * 8, y: y * 8)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        for name in ["back", "back-with-workspace"] {
            XCTAssertGreaterThan(brightness(name, 7, 12), 0.9, "Left arrow tip")
            XCTAssertGreaterThan(brightness(name, 17, 12), 0.9, "Arrow shaft, not just a chevron")
            XCTAssertGreaterThan(brightness(name, 12, 7), 0.9)
            XCTAssertLessThan(brightness(name, 16, 8), 0.1, "No remaining X arm")
        }
        for name in ["dots-back-bead", "close-back-bead"] {
            XCTAssertGreaterThan(brightness(name, 12, 12), 0.9)
            XCTAssertLessThan(brightness(name, 8, 8), 0.1)
            XCTAssertLessThan(brightness(name, 17, 12), 0.1)
        }
        XCTAssertGreaterThan(brightness("close-back-reduced", 17, 12), 0.3, "Reduce Motion crossfades without contracting")
        if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, bitmap) in samples {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("morph-\(name).png"))
            }
        }
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
        // The slider occupies subdivisions 0 and 1; Keep Awake keeps the left third.
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

    func testSettingsSubmenuRevealsSliderAndKeepAwakeAndPinsHoverWhileDragging() {
        let model = SessionWheelModel()
        let slot = SessionWheelShortcut.settings.rawValue
        model.hover(at: geometry.position(slot: slot, radius: 119))
        XCTAssertTrue(model.isHoveringSettings)
        XCTAssertEqual(model.submenuSlot, slot)
        model.hover(at: geometry.position(slot: slot, radius: geometry.wheelRadius + 4))
        XCTAssertEqual(model.submenuSlot, slot, "Hover continues across the gap")
        XCTAssertNil(model.hoveredSettingsControl)
        for (index, control) in [(0, SessionWheelSettingsControl.intensity), (1, .intensity), (2, .keepAwake)] {
            model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(index)))
            XCTAssertEqual(model.hoveredSettingsControl, control)
            XCTAssertNil(model.hoveredNoteAction)
            XCTAssertNil(model.hoveredAction)
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

        model.showProjects(at: geometry.center)
        model.hover(at: geometry.position(slot: slot, radius: 119))
        XCTAssertFalse(model.isHoveringSettings)
        XCTAssertNil(model.submenuSlot)
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
        controller.refresh = { model, _ in
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
            controller.refresh?(controller.model, false)
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
        let keepAwake = geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(2))
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
        controller.refresh = { model, _ in model.keepAwake = state }
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
        controller.refresh?(controller.model, false)
        controller.performKeepAwake()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.model.keepAwake, .off)
        XCTAssertEqual(pulses, [.generic, .generic])
        controller.keepAwakeAction = { false }
        controller.performKeepAwake()
        XCTAssertEqual(controller.model.notice, "Keep Awake unavailable")
        XCTAssertEqual(pulses.count, 2)
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
        model.refresh(sessions: [
            .init(id: "relay", name: "Relay Runner", unreadCount: 2, isFocused: true, playback: .play),
            .init(id: "hidpress", name: "hidpress", isRecording: true),
            .init(id: "general", name: "general-tasks", canPlay: false)
        ])
        model.projects = ["Vial QMK", "Hidpress Web", "ESP32 Bridge", "Website", "Voice Notes", "Research", "Playground"]
            .enumerated().map { .init(id: "\($0.offset)", name: $0.element, path: "/\($0.offset)") }
        let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performAction: { _, _ in },
                                    selectCenter: {}, back: {}, dismiss: {}, recordingLevel: { _ in 1 })
        for state in ["sessions", "working", "response-ready", "listening", "paused", "workspace-open", "session-notice", "controls", "play-hover", "recording-controls", "projects", "last-page", "limit",
                      "design-recording", "design-idle", "design-play", "design-playback",
                      "shortcuts-empty", "notes-idle", "notes-recording", "notes-paused", "notes-saving",
                      "more-sessions", "all-sessions",
                      "settings-min", "settings-max", "settings-keep-awake-off", "settings-keep-awake-on",
                      "settings-keep-awake-pending", "settings-keep-awake-approval", "settings-keep-awake-failed",
                      "settings-restore", "settings-particles-off", "settings-dragging"]
            + (0..<geometry.slotCount).map({ "contour-\($0)" }) {
            switch state {
            case "working": model.notchStatus = .working
            case "response-ready": model.notchStatus = .playing
            case "listening": model.notchStatus = .listening
            case "paused": model.notchStatus = .paused
            case "workspace-open": model.isWorkspaceVisible = true
            case "session-notice": model.notice = "Session could not start"
            case "controls":
                model.notice = nil
                model.isWorkspaceVisible = false
                model.hover(at: geometry.position(slot: 0, radius: 119))
            case "play-hover":
                model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius, offset: geometry.actionOffset(.message)))
            case "recording-controls":
                model.hover(at: geometry.position(slot: 1, radius: 119))
                model.hover(at: geometry.position(slot: 1, radius: geometry.actionRadius))
            case "projects": model.showProjects(at: geometry.center)
            case "last-page": model.turnPage(1, at: geometry.center)
            case "limit": model.startUnavailableReason = "Session limit reached"
            case "shortcuts-empty":
                model.reset(at: geometry.center)
                model.refresh(sessions: [])
                model.startUnavailableReason = nil
                model.isWorkspaceVisible = false
                model.notchStatus = .notWorking
            case "notes-idle", "notes-recording", "notes-paused", "notes-saving":
                model.notePhase = state == "notes-recording" ? .recording
                    : state == "notes-paused" ? .paused
                    : state == "notes-saving" ? .transcribing : .idle
                model.hover(at: geometry.position(slot: SessionWheelShortcut.noteTaker.rawValue, radius: 119))
            case "settings-min", "settings-max", "settings-keep-awake-off", "settings-keep-awake-on",
                 "settings-keep-awake-pending", "settings-keep-awake-approval", "settings-keep-awake-failed",
                 "settings-restore", "settings-particles-off", "settings-dragging":
                model.reset(at: geometry.center)
                model.notePhase = .idle
                model.particleFieldEnabled = state != "settings-particles-off"
                model.particleIntensity = state == "settings-min" ? 0.1 : state == "settings-max" ? 1.0 : 0.6
                model.keepAwake = state == "settings-keep-awake-on" ? .on(ownsSleepSetting: true)
                    : state == "settings-keep-awake-pending" ? .enabling
                    : state == "settings-keep-awake-approval" ? .awaitingApproval
                    : state == "settings-keep-awake-failed" ? .failed(KeepAwakePowerHelper.missingMessage)
                    : state == "settings-restore" ? .restoreNeeded("Restore") : .off
                let slot = SessionWheelShortcut.settings.rawValue
                model.hover(at: geometry.position(slot: slot, radius: 119))
                let hoversKeepAwake = ["settings-keep-awake-off", "settings-keep-awake-on"].contains(state)
                model.hover(at: geometry.position(slot: slot, radius: geometry.actionRadius,
                                                  offset: geometry.actionOffset(hoversKeepAwake ? 2 : 0)))
                if state == "settings-dragging" {
                    model.adjustIntensity(to: geometry.position(slot: slot, radius: geometry.actionRadius,
                                                                offset: -geometry.sliceAngle / 6))
                    model.endAdjustingIntensity()
                }
            case "more-sessions", "all-sessions":
                model.reset(at: geometry.center)
                model.notePhase = .idle
                model.refresh(sessions: (0..<4).map { .init(id: "\($0)", name: "Project \($0 + 1)") })
                if state == "all-sessions" { model.showAllSessions(at: geometry.center) }
            case "design-recording", "design-idle", "design-play", "design-playback":
                model.reset(at: geometry.center)
                model.startUnavailableReason = nil
                model.isWorkspaceVisible = state == "design-recording" || state == "design-play"
                let sessions: [SessionWheelSession] = [
                    .init(id: "general", name: "General Tasks", isFocused: true,
                          isRecording: state == "design-recording",
                          canPlay: state == "design-play" || state == "design-playback",
                          playback: state == "design-playback" ? .stop : .play),
                    .init(id: "hidpress", name: "Hidpress Web"),
                    .init(id: "placeholder", name: ""),
                    .init(id: "relay", name: "Relay Runner")
                ]
                model.refresh(sessions: [])
                model.refresh(sessions: sessions)
                model.refresh(sessions: sessions.filter { $0.id != "placeholder" })
                model.hover(at: geometry.position(slot: 0, radius: 119))
            default:
                if state.hasPrefix("contour-"), let slot = Int(state.suffix(1)) {
                    model.reset(at: geometry.center)
                    model.startUnavailableReason = nil
                    model.refresh(sessions: (0..<geometry.slotCount).map {
                        .init(id: "\($0)", name: "Project \($0 + 1)", isRecording: $0 == 1, canPlay: $0 != 2)
                    })
                    model.showAllSessions(at: geometry.center)
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
