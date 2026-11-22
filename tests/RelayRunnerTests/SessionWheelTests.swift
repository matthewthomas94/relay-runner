import SwiftUI
import XCTest
@testable import relay_runner

final class SessionWheelTests: XCTestCase {
    private let geometry = SessionWheelGeometry.self
    private func makeController() -> SessionWheelController {
        SessionWheelController(haptics: .init(perform: { _ in }))
    }
    private func session(_ id: String) -> SessionWheelSession { .init(id: id, name: id) }
    private let agents = SessionAgent.allCases
    private var bounds: CGRect { CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter)) }
    private func itemPoint(_ index: Int) -> CGPoint {
        let arc = geometry.sessionItemArc(index)
        return geometry.position(slot: 0, radius: geometry.actionRadius, offset: arc.start + arc.width / 2)
    }
    private func labelPoint(_ index: Int) -> CGPoint {
        geometry.sessionAgentLayout(index, label: agents[index].shortLabel).label.point
    }
    private func glyphPoint(_ index: Int) -> CGPoint {
        geometry.sessionGlyphPoint(index, label: agents[index].shortLabel)
    }
    /// RR-521: Puck active, Isabella and George running, Sky stopped, as in the mockup.
    private func mockupAgents(_ model: SessionWheelModel) {
        model.runningAgents = [.puck, .isabella, .george]
        model.activeAgent = .puck
    }
    private func openSessionSubmenu(_ model: SessionWheelModel) {
        model.hover(at: geometry.position(slot: 0, radius: 119))
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

    /// RR-521: every agent's label and glyph is reachable across the radial
    /// gap, with or without a session running.
    func testEveryAgentSegmentAndGlyphIsReachableAcrossTheRadialGap() {
        for running in [false, true] {
            let model = SessionWheelModel()
            if running {
                model.refresh(sessions: [session("pm")])
                mockupAgents(model)
            }
            openSessionSubmenu(model)
            XCTAssertEqual(model.hoveredSlot, 0)
            XCTAssertEqual(model.submenuSlot, 0, "The submenu opens whether or not a session runs")
            model.hover(at: geometry.position(slot: 0, radius: (geometry.wheelRadius + geometry.actionInnerRadius) / 2))
            XCTAssertEqual(model.submenuSlot, 0)
            XCTAssertNil(model.hoveredSessionItem)
            let items = model.sessionItems
            XCTAssertEqual(items.count, 4)
            for (index, item) in items.enumerated() {
                let point = labelPoint(index)
                model.hover(at: point)
                XCTAssertEqual(model.hoveredSlot, 0, "item \(index)")
                XCTAssertEqual(model.hoveredSessionItem, item, "item \(index)")
                XCTAssertNil(model.hoveredGlyph, "The label side of a segment is the label")
                XCTAssertEqual(model.hoveredAgentAction, item.labelAction)
                let arc = geometry.sessionItemArc(index)
                let shape = SessionWheelSector(slot: 0, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius,
                                               arcStart: arc.start, arcWidth: arc.width)
                XCTAssertTrue(shape.path(in: bounds).contains(point))
                XCTAssertTrue(geometry.contains(point, submenuSlot: 0))
                // The glyph sits inside its own segment, clear of the edges.
                let glyph = glyphPoint(index)
                for step in 0..<12 {
                    let angle = CGFloat(step) * .pi / 6
                    let edge = CGPoint(x: glyph.x + geometry.agentGlyphHitRadius * cos(angle),
                                       y: glyph.y + geometry.agentGlyphHitRadius * sin(angle))
                    XCTAssertTrue(shape.path(in: bounds).contains(edge), "glyph of item \(index)")
                }
                model.hover(at: glyph)
                XCTAssertEqual(model.hoveredSessionItem, item)
                XCTAssertEqual(model.hoveredGlyph, item, "item \(index)")
                XCTAssertEqual(model.hoveredAgentAction, item.glyphAction)
                XCTAssertEqual(model.hoverDescriptor(at: glyph), item.glyphAction.title)
            }
        }
    }

    /// RR-521: the four segments fit the submenu's standard size over the
    /// session's own cell and never reach History or Workspace.
    func testSessionSubmenuIsOneCellForTheFourAgents() {
        XCTAssertEqual(geometry.sessionItemCount, 4)
        let first = geometry.sessionItemArc(0)
        let last = geometry.sessionItemArc(3)
        XCTAssertEqual(first.start, -geometry.sliceAngle / 2, accuracy: 0.0001)
        XCTAssertEqual(last.start + last.width, geometry.sliceAngle / 2, accuracy: 0.0001)
        for index in 0..<4 {
            XCTAssertEqual(geometry.sessionItemArc(index).width, geometry.sliceAngle / 4, accuracy: 0.0001)
            XCTAssertEqual(geometry.sessionItem(at: itemPoint(index)), index)
        }
        for slot in 1..<geometry.slotCount {
            let point = geometry.position(slot: slot, radius: geometry.actionRadius)
            XCTAssertNil(geometry.sessionItem(at: point), "Slot \(slot)")
            XCTAssertFalse(geometry.contains(point, submenuSlot: 0))
        }
        let source = try? String(contentsOfFile: #filePath
            .replacingOccurrences(of: "tests/RelayRunnerTests/SessionWheelTests.swift",
                                  with: "Sources/relay-runner/Board/SessionWheelModel.swift"), encoding: .utf8)
        for removed in ["sessionSubmenuSpan", "sessionStandardItems", "sessionMaxItems", "SessionTabEntry", "sessionWeight"] {
            XCTAssertEqual(source?.contains(removed), false, removed)
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
        XCTAssertEqual(SessionWheelShortcut.history.symbol, .rotateCcwClock)
        XCTAssertEqual(SessionWheelSessionSlot.title, "Terminal")
        XCTAssertEqual(SessionWheelSessionSlot.symbol, .squareTerminal)
        model.refresh(sessions: [session("a")])
        XCTAssertEqual(model.slots[0]?.id, "a")
        XCTAssertTrue([1, 2, 3, 4].allSatisfy { model.slots[$0] == nil })
    }

    /// RR-521: with no session running the submenu still lists the four
    /// agents in order, none running, and there is no Add control.
    func testWithNoSessionTheSubmenuIsTheFourAgentsNoneRunning() {
        let model = SessionWheelModel()
        XCTAssertEqual(model.sessionItems.map(\.agent), [.puck, .isabella, .george, .sky])
        XCTAssertTrue(model.sessionItems.allSatisfy { !$0.isRunning && !$0.isActive })
        XCTAssertTrue(model.sessionItems.allSatisfy { $0.glyph == .plus })
        XCTAssertTrue(model.sessionItems.allSatisfy { $0.labelAction == .start($0.agent) && $0.glyphAction == .start($0.agent) })
        model.refresh(sessions: [session("a")])
        mockupAgents(model)
        XCTAssertEqual(model.sessionItems.map(\.agent), [.puck, .isabella, .george, .sky], "The order never changes")
        model.refresh(sessions: [])
        model.runningAgents = []
        XCTAssertEqual(model.sessionItems.count, 4)
    }

    /// The segments are labelled PK, IS, GE and SK from the agent definition.
    func testAgentSegmentsUseTheTwoLetterLabels() {
        XCTAssertEqual(SessionAgent.allCases.map(\.shortLabel), ["PK", "IS", "GE", "SK"])
        XCTAssertEqual(SessionWheelModel().sessionItems.map(\.label), ["PK", "IS", "GE", "SK"])
        XCTAssertEqual(SessionWheelModel().sessionItems.map(\.name), ["Puck", "Isabella", "George", "Sky"])
    }

    /// A running agent shows the X, which stops it; a stopped one the plus,
    /// which starts it. Only a running agent can be active.
    func testRunningAgentsShowTheXAndStoppedOnesThePlus() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        mockupAgents(model)
        let items = model.sessionItems
        XCTAssertEqual(items.map(\.glyph), [.x, .x, .x, .plus])
        XCTAssertEqual(items.map(\.isActive), [true, false, false, false])
        XCTAssertEqual(items.map(\.glyphAction), [.stop(.puck), .stop(.isabella), .stop(.george), .start(.sky)])
        XCTAssertEqual(items.map(\.labelAction), [.switchTo(.puck), .switchTo(.isabella), .switchTo(.george), .start(.sky)])
        model.activeAgent = .sky
        XCTAssertFalse(model.sessionItems[3].isActive, "A stopped agent is never active")
        model.runningAgents.insert(.sky)
        XCTAssertEqual(model.sessionItems[3].glyph, .x, "The glyph follows the agent's state")
        XCTAssertTrue(model.sessionItems[3].isActive)
    }

    /// RR-521, from the mockup: grey X for running, primary plus for stopped,
    /// orange label for the active agent, and no dimmed labels.
    func testAgentLabelAndGlyphColoursFollowTheMockup() {
        let model = SessionWheelModel()
        mockupAgents(model)
        let items = model.sessionItems
        XCTAssertEqual(items.map(SessionWheelView.agentLabelColor),
                       [ProgramBoardStyle.activeTrayOrange, ProgramBoardStyle.primaryText,
                        ProgramBoardStyle.primaryText, ProgramBoardStyle.primaryText])
        XCTAssertEqual(items.map { SessionWheelView.agentGlyphColor($0, hovered: false) },
                       [ProgramBoardStyle.mutedText, ProgramBoardStyle.mutedText,
                        ProgramBoardStyle.mutedText, ProgramBoardStyle.primaryText])
        XCTAssertEqual(SessionWheelView.agentGlyphColor(items[1], hovered: true), ProgramBoardStyle.primaryText)
        let source = try? String(contentsOfFile: #filePath
            .replacingOccurrences(of: "tests/RelayRunnerTests/SessionWheelTests.swift",
                                  with: "Sources/relay-runner/Board/SessionWheelView.swift"), encoding: .utf8)
        XCTAssertEqual(source?.contains("dimmed:"), false, "No agent label is dimmed")
        XCTAssertEqual(source?.contains(".opacity(dimmed"), false, "No agent label is dimmed")
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
            XCTAssertEqual(SessionWheelNoteAction.recording.symbol(for: phase), .mic)
            XCTAssertFalse(SessionWheelNoteAction.cancel.isEnabled(for: phase))
            XCTAssertFalse(SessionWheelNoteAction.pause.isEnabled(for: phase))
        }
        for phase in [MeetingNoteCoordinatorPhase.recording, .paused] {
            XCTAssertTrue(SessionWheelNoteAction.recording.isEnabled(for: phase))
            XCTAssertEqual(SessionWheelNoteAction.recording.symbol(for: phase), .check)
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
        XCTAssertEqual(SessionWheelNoteAction.cancel.symbol(for: .recording), .x)
        XCTAssertEqual(SessionWheelNoteAction.recording.title(for: .recording), "Save note")
        let positions = [SessionWheelNoteAction.pause, .recording, .cancel].map {
            geometry.position(slot: 3, radius: geometry.actionRadius, offset: geometry.actionOffset($0.rawValue)).x
        }
        XCTAssertEqual(positions, positions.sorted(), "Pause/Resume, Start/Save, Cancel read left to right")
        XCTAssertEqual(SessionWheelNoteAction.pause.title(for: .paused), "Resume Notetaker")
        XCTAssertEqual(SessionWheelNoteAction.pause.symbol(for: .paused), .play)
        XCTAssertEqual(SessionWheelNoteAction.pause.symbol(for: .recording), .pause)
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

    /// RR-521: starting the first agent or stopping the last keeps the submenu open.
    func testStartingAndStoppingSessionsKeepsTheSubmenuHovered() {
        let model = SessionWheelModel()
        openSessionSubmenu(model)
        model.hover(at: glyphPoint(0))
        XCTAssertEqual(model.hoveredAgentAction, .start(.puck))
        model.refresh(sessions: [session("a")])
        model.runningAgents = [.puck]
        model.activeAgent = .puck
        XCTAssertEqual(model.submenuSlot, 0)
        XCTAssertEqual(model.hoveredAgentAction, .stop(.puck), "The glyph swaps in place under the pointer")
        model.refresh(sessions: [])
        model.runningAgents = []
        XCTAssertEqual(model.submenuSlot, 0)
        XCTAssertEqual(model.hoveredAgentAction, .start(.puck))
    }

    @MainActor
    func testCenterClosesTheWheel() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.agentAction = { _ in XCTFail("The centre never starts a session"); return false }
        controller.openTerminal = { XCTFail("The centre never opens the terminal") }

        controller.toggle()
        controller.selectCenter()
        XCTAssertFalse(controller.isVisible)
    }

    /// RR-521: the session slot always opens Workspace on the Terminal tab,
    /// with or without a session, and never starts one.
    @MainActor
    func testSessionSlotOnlyOpensTheTerminalAndKeepsTheWheelOpen() {
        _ = NSApplication.shared
        for running in [false, true] {
            for fromPointer in [false, true] {
                let controller = makeController()
                defer { controller.dismiss() }
                controller.refresh = { model in
                    model.refresh(sessions: running ? [.init(id: "a", name: "Puck", isFocused: true)] : [])
                }
                var opens = 0
                controller.openTerminal = {
                    XCTAssertTrue(controller.isVisible)
                    opens += 1
                }
                controller.agentAction = { _ in XCTFail("The session slot never starts an agent"); return false }
                controller.toggle()
                for shortcut in [1, 2, 3, 4] { controller.selectSlot(shortcut, fromPointer: fromPointer) }
                XCTAssertEqual(opens, 0, "Only the session slot opens the terminal")
                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertTrue(controller.isVisible)
                XCTAssertEqual(opens, 1)
                XCTAssertEqual(controller.model.slots[0] != nil, running)
                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertEqual(opens, 2)
                controller.dismiss()
                controller.selectSlot(0, fromPointer: fromPointer)
                XCTAssertEqual(opens, 2)
            }
        }
        let model = SessionWheelModel()
        openSessionSubmenu(model)
        XCTAssertEqual(model.hoverDescriptor(at: geometry.position(slot: 0, radius: 119)), "Open terminal tab")
        XCTAssertEqual(SessionWheelSessionSlot.title, "Terminal")
        let source = try? String(contentsOfFile: #filePath
            .replacingOccurrences(of: "tests/RelayRunnerTests/SessionWheelTests.swift",
                                  with: "Sources/relay-runner/Board/SessionWheelModel.swift"), encoding: .utf8)
        XCTAssertEqual(source?.contains("isStartSlot"), false)
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

    /// RR-521: a stopped agent's label and plus both start it; a running
    /// agent's label switches to it and its X stops it. The wheel stays open
    /// throughout, including when the first agent starts the session.
    @MainActor
    func testAgentLabelsAndGlyphsRequestStartSwitchAndStop() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        var running: [SessionAgent] = []
        var active: SessionAgent?
        var performed: [SessionWheelAgentAction] = []
        controller.refresh = { model in
            model.refresh(sessions: running.isEmpty ? [] : [.init(id: "pm", name: "Puck", isFocused: true)])
            model.runningAgents = Set(running)
            model.activeAgent = active
        }
        controller.agentAction = { action in
            performed.append(action)
            switch action {
            case .start(let agent): running.append(agent); active = agent
            case .switchTo(let agent): active = agent
            case .stop(let agent):
                running.removeAll { $0 == agent }
                if active == agent { active = running.first }
            }
            return true
        }
        controller.toggle()
        let model = controller.model
        func click(_ agent: SessionAgent, glyph: Bool) {
            let item = model.sessionItems[agent.order - 1]
            controller.performAgentAction(glyph ? item.glyphAction : item.labelAction)
            XCTAssertTrue(controller.isVisible)
        }
        click(.puck, glyph: false)
        XCTAssertEqual(performed.last, .start(.puck), "A stopped agent's name starts it, and the session with it")
        click(.isabella, glyph: true)
        XCTAssertEqual(performed.last, .start(.isabella), "A stopped agent's plus starts it")
        XCTAssertEqual(model.activeAgent, .isabella, "A start makes the agent active")
        click(.puck, glyph: false)
        XCTAssertEqual(performed.last, .switchTo(.puck), "A running agent's name switches to it")
        XCTAssertEqual(model.sessionItems.first(where: \.isActive)?.agent, .puck)
        click(.isabella, glyph: true)
        XCTAssertEqual(performed.last, .stop(.isabella), "A running agent's X stops it")
        click(.puck, glyph: true)
        XCTAssertEqual(performed.last, .stop(.puck))
        XCTAssertTrue(model.runningAgents.isEmpty)
        XCTAssertNil(model.slots[0], "Stopping the last agent ends the session")
        XCTAssertEqual(performed.count, 5)

        // A start waits while another is starting; switching and stopping never do.
        model.startUnavailableReason = "Agent starting"
        controller.performAgentAction(.start(.sky))
        XCTAssertEqual(performed.count, 5)
        XCTAssertFalse(model.isEnabled(.start(.sky)))
        XCTAssertTrue(model.isEnabled(.stop(.sky)))
        XCTAssertTrue(model.isEnabled(.switchTo(.sky)))
    }

    @MainActor
    func testRefusedAgentActionShowsANotice() {
        _ = NSApplication.shared
        let controller = makeController()
        defer { controller.dismiss() }
        controller.agentAction = { _ in false }
        controller.toggle()
        controller.performAgentAction(.start(.george))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.model.notice, "Couldn't start George")
        controller.performAgentAction(.stop(.george))
        XCTAssertEqual(controller.model.notice, "Couldn't stop George")
        controller.performAgentAction(.switchTo(.george))
        XCTAssertEqual(controller.model.notice, "Couldn't switch agents")
        for action in [SessionWheelAgentAction.start(.isabella), .stop(.isabella), .switchTo(.isabella)] {
            XCTAssertTrue(NotchHoverDescriptor.isValid(action.failureNotice), action.failureNotice)
        }
    }

    /// A segment is labelled with its agent's two letters. Its label and
    /// glyph sit apart like `space-between`: the same padding inside each end
    /// of the segment, the glyph after the label in reading order, never overlapping.
    func testAgentSegmentSpacesItsLabelAndGlyphApart() {
        let radius = geometry.actionRadius
        let diameter = geometry.agentGlyphDiameter
        for index in 0..<geometry.sessionItemCount {
            let arc = geometry.sessionItemArc(index)
            let text = agents[index].shortLabel
            let layout = geometry.sessionAgentLayout(index, label: text)
            let width = geometry.trackedLetters(text).width
            let axis = CGPoint(x: cos(layout.label.rotation), y: sin(layout.label.rotation))
            let along = (layout.glyph.point.x - layout.label.point.x) * axis.x
                + (layout.glyph.point.y - layout.label.point.y) * axis.y
            XCTAssertGreaterThanOrEqual(along, width / 2 + diameter / 2 - 0.5, "item \(index)")
            XCTAssertEqual(layout.glyph.rotation - layout.label.rotation,
                           geometry.sessionArcOffset(at: layout.glyph.point) - geometry.sessionArcOffset(at: layout.label.point),
                           accuracy: 0.0001, "The glyph turns with its label")
            // Padding inside each end of the segment, along the arc.
            let label = geometry.sessionArcOffset(at: layout.label.point)
            let glyph = geometry.sessionArcOffset(at: layout.glyph.point)
            let (leading, trailing) = glyph > label ? (arc.start, arc.start + arc.width) : (arc.start + arc.width, arc.start)
            let leadingPadding = abs(label - leading) * radius - width / 2 - geometry.segmentGap / 2
            let trailingPadding = abs(trailing - glyph) * radius - diameter / 2 - geometry.segmentGap / 2
            XCTAssertEqual(leadingPadding, trailingPadding, accuracy: 0.01, "item \(index)")
            XCTAssertGreaterThanOrEqual(leadingPadding, 4, "item \(index)")
            XCTAssertLessThanOrEqual(leadingPadding, geometry.agentContentPadding + 0.01)
            // The label curves with the cell: every letter sits on the arc, give or
            // take the slight tilt, in reading order, and its outline stays inside the band.
            XCTAssertEqual(layout.glyphs.count, text.count)
            for letter in layout.glyphs {
                XCTAssertEqual(letter.rotation - layout.label.rotation,
                               geometry.sessionArcOffset(at: letter.point) - label + geometry.agentLabelTilt,
                               accuracy: 0.01, "Each letter follows the arc, turned by the tilt")
                XCTAssertEqual(hypot(letter.point.x - geometry.center.x, letter.point.y - geometry.center.y),
                               radius, accuracy: 1.5)
                var distances: [CGFloat] = []
                letter.outline.applyWithBlock { element in
                    let count = switch element.pointee.type {
                    case .moveToPoint, .addLineToPoint: 1
                    case .addQuadCurveToPoint: 2
                    case .addCurveToPoint: 3
                    default: 0
                    }
                    for point in UnsafeBufferPointer(start: element.pointee.points, count: count) {
                        distances.append(hypot(point.x - geometry.center.x, point.y - geometry.center.y))
                    }
                }
                guard !distances.isEmpty else { continue }
                XCTAssertGreaterThan(distances.min() ?? 0, radius - 8, "item \(index)")
                XCTAssertLessThan(distances.max() ?? .infinity, radius + 8, "item \(index)")
            }
            let offsets = layout.glyphs.map { geometry.sessionArcOffset(at: $0.point) }
            XCTAssertEqual(offsets, glyph > label ? offsets.sorted() : offsets.sorted(by: >), "item \(index)")
        }
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
        let model = SessionWheelModel()
        mockupAgents(model)
        for item in model.sessionItems {
            captions += [model.caption(for: item.labelAction), model.caption(for: item.glyphAction)]
        }
        captions += ["Agent starting", "Finish notes first"]
        for caption in captions {
            XCTAssertTrue(NotchHoverDescriptor.isValid(caption), caption)
        }
        // RR-521: the notch and VoiceOver name the action and the agent in full.
        for agent in SessionAgent.allCases {
            XCTAssertEqual(SessionWheelAgentAction.start(agent).title, "Start \(agent.name)")
            XCTAssertEqual(SessionWheelAgentAction.switchTo(agent).title, "Switch to \(agent.name)")
            XCTAssertEqual(SessionWheelAgentAction.stop(agent).title, "Stop \(agent.name)")
        }
        XCTAssertEqual(model.caption(for: .start(.sky)), "Start Sky")
        XCTAssertEqual(model.caption(for: .switchTo(.isabella)), "Switch to Isabella")
        XCTAssertEqual(model.caption(for: .stop(.george)), "Stop George")
        XCTAssertEqual(model.caption(for: .switchTo(.puck)), "Puck active", "The active agent has nothing to switch to")
        model.startUnavailableReason = "Agent starting"
        XCTAssertEqual(model.caption(for: .start(.sky)), "Agent starting")
        XCTAssertEqual(model.caption(for: .stop(.george)), "Stop George")
        for text in captions {
            XCTAssertNil(text.range(of: #"\bS(ession )?[0-9]"#, options: .regularExpression), text)
        }
        XCTAssertEqual(SessionWheelNoteAction.pause.caption(for: .recording), "Pause note")
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
        XCTAssertEqual(hint(slot: 0), "Open terminal tab", "RR-521: also with no session running")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.history.rawValue), "Open history tab")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.workspace.rawValue), "Open workspace tab")
        XCTAssertEqual(hint(slot: SessionWheelShortcut.noteTaker.rawValue), "Open notetaker tab")
        let settings = SessionWheelShortcut.settings.rawValue
        XCTAssertEqual(hint(slot: settings), "Open settings tab", "The parent alone, not its Autoplay control")
        XCTAssertEqual(hint(slot: settings, radius: geometry.wheelRadius + 4), "Open settings tab", "The gap keeps the parent")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(5, subdivisions: 6)), "Turn on autoplay")
        model.autoPlay = true
        XCTAssertEqual(model.hoverDescriptor(at: geometry.position(slot: settings, radius: geometry.actionRadius,
                                                                   offset: geometry.actionOffset(5, subdivisions: 6))),
                       "Turn off autoplay")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(4, subdivisions: 6)), "Keep Mac awake")
        XCTAssertEqual(hint(slot: settings, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(0, subdivisions: 6)), "Adjust particle intensity")
        model.particleFieldEnabled = false
        XCTAssertEqual(model.hoverDescriptor(at: geometry.position(slot: settings, radius: geometry.actionRadius)),
                       "Particles turned off")

        let noteTaker = SessionWheelShortcut.noteTaker.rawValue
        _ = hint(slot: noteTaker)
        XCTAssertEqual(hint(slot: noteTaker, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(SessionWheelNoteAction.cancel.rawValue)), "Discard note")
        XCTAssertEqual(hint(slot: noteTaker, radius: geometry.actionRadius,
                            offset: geometry.actionOffset(SessionWheelNoteAction.recording.rawValue)), "Start new note")

        // RR-521: the session slot never starts a session, so its hint never changes.
        XCTAssertEqual(hint(slot: 0), "Open terminal tab")
        model.hover(at: labelPoint(0))
        XCTAssertEqual(model.hoverDescriptor(at: labelPoint(0)), "Start Puck")
        model.hover(at: glyphPoint(0))
        XCTAssertEqual(model.hoverDescriptor(at: glyphPoint(0)), "Start Puck")
        model.startUnavailableReason = "Finish notes first"
        XCTAssertEqual(model.hoverDescriptor(at: glyphPoint(0)), "Finish notes first")
        model.startUnavailableReason = nil
        model.refresh(sessions: [.init(id: "a", name: "general")])
        mockupAgents(model)
        XCTAssertEqual(hint(slot: 0), "Open terminal tab")
        model.hover(at: labelPoint(0))
        XCTAssertEqual(model.hoverDescriptor(at: labelPoint(0)), "Puck active")
        model.hover(at: labelPoint(1))
        XCTAssertEqual(model.hoverDescriptor(at: labelPoint(1)), "Switch to Isabella")
        model.hover(at: glyphPoint(1))
        XCTAssertEqual(model.hoverDescriptor(at: glyphPoint(1)), "Stop Isabella")
        model.hover(at: labelPoint(3))
        XCTAssertEqual(model.hoverDescriptor(at: labelPoint(3)), "Start Sky")
        model.hover(at: glyphPoint(3))
        XCTAssertEqual(model.hoverDescriptor(at: glyphPoint(3)), "Start Sky")

        model.hover(at: geometry.center)
        XCTAssertEqual(model.hoverDescriptor(at: geometry.center), "Close session wheel")
        model.notice = "Couldn't start session"
        XCTAssertEqual(model.hoverDescriptor(at: geometry.center), "Couldn't start session")
        let outside = CGPoint(x: -30, y: -30)
        model.hover(at: outside)
        XCTAssertNil(model.hoverDescriptor(at: outside))
        for hint in ["Open terminal tab", "Finish notes first", "Turn on autoplay", "Keep Mac awake", "Adjust particle intensity"] {
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
        XCTAssertFalse(controller.model.isHoveringSettings)

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

    func testKeepAwakeGlyphUsesABoltAndSwapsOnlyForPendingApprovalAndFailures() {
        typealias Look = SessionWheelKeepAwakeGlyph.Look
        let off = Look(.off)
        let on = Look(.on(ownsSleepSetting: true))
        XCTAssertEqual(off.symbol, .zap)
        XCTAssertEqual(on.symbol, .zap)
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
            XCTAssertFalse(Look(state).symbol.geometry.stroke.isEmpty, "\(state)")
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
        model.refresh(sessions: [.init(id: "pm", name: "Puck", isFocused: true)])
        mockupAgents(model)
        let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performAgentAction: { _ in },
                                    selectCenter: {}, dismiss: {})
        for state in ["sessions", "session-notice", "controls", "agents-mockup", "agents-stop-hover", "agents-start-hover",
                      "agents-none", "agents-all",
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
            case "agents-mockup", "agents-stop-hover", "agents-start-hover", "agents-none", "agents-all":
                // RR-521: the four agents' segments; agents-mockup matches the ticket's mockup.
                model.reset(at: geometry.center)
                let none = state == "agents-none"
                model.refresh(sessions: none ? [] : [.init(id: "pm", name: "Puck", isFocused: true)])
                mockupAgents(model)
                if none { model.runningAgents = [] }
                if state == "agents-all" { model.runningAgents = Set(SessionAgent.allCases) }
                openSessionSubmenu(model)
                model.hover(at: state == "agents-stop-hover" ? glyphPoint(1)
                            : state == "agents-start-hover" ? glyphPoint(3) : geometry.position(slot: 0, radius: 119))
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
                    mockupAgents(model)
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
