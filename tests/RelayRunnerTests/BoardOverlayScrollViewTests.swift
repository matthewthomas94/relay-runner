import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import relay_runner

@MainActor
final class BoardOverlayScrollViewTests: XCTestCase {
    func testColumnAlignedContentInsetsMatchLaneEdges() {
        XCTAssertEqual(BoardOverlayScrollContentInsets.columnAligned.leading, 0)
        XCTAssertEqual(BoardOverlayScrollContentInsets.columnAligned.trailing, 0)
        XCTAssertEqual(
            BoardOverlayScrollContentInsets.columnAligned.top,
            BoardOverlayScrollContentInsets.standard.top
        )
        XCTAssertEqual(
            BoardOverlayScrollContentInsets.columnAligned.bottom,
            BoardOverlayScrollContentInsets.standard.bottom
        )
    }

    func testShortContentKeepsInsetEdgesWhileDocumentFillsViewport() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 40)))

        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertEqual(views.documentView.frame.height, views.scrollView.contentView.bounds.height, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.height, 40, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(views.documentView.frame.maxY - views.hostingView.frame.maxY, 0)
    }

    func testTallContentExpandsDocumentForScrollingWithReachableEdges() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 520)))

        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertGreaterThan(views.documentView.frame.height, views.scrollView.contentView.bounds.height)
        XCTAssertEqual(views.hostingView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.height, 520, accuracy: 0.5)
        XCTAssertEqual(
            views.hostingView.frame.maxY,
            views.documentView.frame.maxY,
            accuracy: 0.5
        )
    }

    func testScrollContainerUsesTopOriginWhenScrolledToBeginning() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 520)))

        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertTrue(views.scrollView.contentView.isFlipped)

        views.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)
        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, 120, accuracy: 0.5)

        views.scrollView.contentView.scroll(to: .zero)
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)

        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(views.hostingView.frame.minY, views.scrollView.documentVisibleRect.minY)
    }

    func testViewportGrowthClampsScrollOffsetIntoReachableRange() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 520)))

        layout(container, width: 200, height: 120)
        let views = try scrollViews(in: container)
        let smallMaxOffset = views.documentView.frame.height - views.scrollView.contentView.bounds.height
        views.scrollView.contentView.scroll(to: NSPoint(x: 0, y: smallMaxOffset))
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)

        layout(container, width: 200, height: 300)

        let largeMaxOffset = views.documentView.frame.height - views.scrollView.contentView.bounds.height
        XCTAssertLessThanOrEqual(views.scrollView.documentVisibleRect.minY, largeMaxOffset + 0.5)
    }

    func testViewportHeightChangeRelayoutsDocumentBounds() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 40)))

        layout(container, width: 200, height: 120)
        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertEqual(views.documentView.frame.height, 300, accuracy: 0.5)
    }

    func testContentReplacementResetsInvalidOffsetToReachableRange() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 520)))

        layout(container, width: 200, height: 120)

        let beforeUpdate = try scrollViews(in: container)
        let maxOffset = beforeUpdate.documentView.frame.height - beforeUpdate.scrollView.contentView.bounds.height
        beforeUpdate.scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
        beforeUpdate.scrollView.reflectScrolledClipView(beforeUpdate.scrollView.contentView)

        container.update(rootView: AnyView(Rectangle().frame(height: 40)))
        layout(container, width: 200, height: 120)

        let afterUpdate = try scrollViews(in: container)
        XCTAssertEqual(afterUpdate.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(afterUpdate.documentView.frame.height, 120, accuracy: 0.5)
    }

    func testScrollContainerUsesVisibleColumnBodyHeightInSwiftUILayout() throws {
        let host = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 16) {
                Text("Done")
                    .frame(height: 32)
                BoardOverlayScrollView {
                    Rectangle().frame(height: 1_200)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(width: 270, height: 633, alignment: .topLeading)
        )
        host.frame = CGRect(x: 0, y: 0, width: 270, height: 633)
        host.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(findScrollContainer(in: host))
        let expectedMaxHeight = CGFloat(633 - 18 * 2 - 32 - 16) + 0.5
        XCTAssertLessThanOrEqual(container.frame.height, expectedMaxHeight)
        XCTAssertGreaterThan(container.frame.height, CGFloat(500))
    }

    func testWorkColumnUsesBoardOverlayScrollContainer() throws {
        let host = NSHostingView(rootView:
            ProgramColumnTicketScrollView {
                Rectangle().frame(height: 1_200)
            }
            .frame(width: 270, height: 633)
        )
        host.frame = CGRect(x: 0, y: 0, width: 270, height: 633)
        host.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(findScrollContainer(in: host))
        let views = try scrollViews(in: container)
        XCTAssertEqual(views.hostingView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(
            views.hostingView.frame.height,
            1_200 + ProgramBoardLayout.workScrollContentInsets.top + ProgramBoardLayout.workScrollContentInsets.bottom,
            accuracy: 1.0
        )
    }

    func testProgramLaneScopeChangeReturnsRealColumnStackToTop() throws {
        let host = NSHostingView(rootView: AnyView(
            programColumnHost(
                resetID: "done-all",
                cardHeights: Array(repeating: 118, count: 16)
            )
        ))
        layout(host, width: 270, height: 633)

        let initialContainer = try XCTUnwrap(findScrollContainer(in: host))
        let initialViews = try scrollViews(in: initialContainer)
        initialViews.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 220))
        initialViews.scrollView.reflectScrolledClipView(initialViews.scrollView.contentView)
        XCTAssertGreaterThan(initialViews.scrollView.documentVisibleRect.minY, 200)

        host.rootView = AnyView(
            programColumnHost(
                resetID: "done-project:/repo/relay-runner",
                cardHeights: [164, 96, 132, 118, 146]
            )
        )
        layout(host, width: 270, height: 633)

        let updatedContainer = try XCTUnwrap(findScrollContainer(in: host))
        let updatedViews = try scrollViews(in: updatedContainer)
        XCTAssertEqual(updatedViews.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5)
        let updatedThumb = try XCTUnwrap(thumbView(in: updatedContainer))
        XCTAssertEqual(updatedThumb.frame.minY, 6, accuracy: 0.5)

        let firstCardMarker = try XCTUnwrap(findFirstCardMarker(in: updatedContainer))
        let firstCardMarkerFrame = firstCardMarker.convert(firstCardMarker.bounds, to: updatedViews.scrollView.contentView)
        let expectedFirstCardContentTop = ProgramBoardLayout.workScrollContentInsets.top
            + ProgramBoardLayout.dropIndicatorHeight
            + ProgramBoardLayout.dropIndicatorBottomPadding
        XCTAssertGreaterThanOrEqual(
            firstCardMarkerFrame.minY,
            expectedFirstCardContentTop - 1.0
        )
        XCTAssertLessThan(firstCardMarkerFrame.maxY, updatedViews.scrollView.contentView.bounds.height)
    }

    func testProgramLaneStacksKeepIndependentOffsetsDuringStableScopeRefresh() throws {
        let host = NSHostingView(rootView: AnyView(
            programColumnsHost(
                backlogResetID: "backlog-all",
                doneResetID: "done-all",
                backlogCardHeights: Array(repeating: 110, count: 12),
                doneCardHeights: Array(repeating: 124, count: 18)
            )
        ))
        layout(host, width: 560, height: 633)

        var containers = findScrollContainers(in: host)
        XCTAssertEqual(containers.count, 2)
        let backlogBefore = try scrollViews(in: containers[0])
        let doneBefore = try scrollViews(in: containers[1])
        backlogBefore.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        backlogBefore.scrollView.reflectScrolledClipView(backlogBefore.scrollView.contentView)
        XCTAssertGreaterThan(backlogBefore.scrollView.documentVisibleRect.minY, 160)
        XCTAssertEqual(doneBefore.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5)

        host.rootView = AnyView(
            programColumnsHost(
                backlogResetID: "backlog-all",
                doneResetID: "done-all",
                backlogCardHeights: [140, 92, 128, 104, 152, 116, 134, 108, 126, 144, 118, 136],
                doneCardHeights: Array(repeating: 132, count: 20)
            )
        )
        layout(host, width: 560, height: 633)

        containers = findScrollContainers(in: host)
        XCTAssertEqual(containers.count, 2)
        let backlogAfter = try scrollViews(in: containers[0])
        let doneAfter = try scrollViews(in: containers[1])
        XCTAssertGreaterThan(backlogAfter.scrollView.documentVisibleRect.minY, 160)
        XCTAssertEqual(doneAfter.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5)
    }

    func testProgramWorkColumnSameScopeNewTopTicketPreservesDoneLaneOffset() throws {
        let model = ProgramBoardViewModel()
        model.snapshot = programDashboardSnapshot(doneItems: doneTickets(start: 100, count: 212))

        let host = NSHostingView(rootView: AnyView(programWorkColumnHost(model: model, lane: .done)))
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)

        let initialContainer = try XCTUnwrap(findScrollContainer(in: host))
        let initialViews = try scrollViews(in: initialContainer)
        initialViews.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 220))
        initialViews.scrollView.reflectScrolledClipView(initialViews.scrollView.contentView)
        XCTAssertGreaterThan(initialViews.scrollView.documentVisibleRect.minY, 200)

        let prependedTitle = "Prepended done ticket that must be complete at the top"
        model.snapshot = programDashboardSnapshot(
            doneItems: [
                programWorkItem(
                    ticketID: "RR-500",
                    title: prependedTitle,
                    status: Ticket.Status.done.rawValue
                ),
            ] + doneTickets(start: 100, count: 212)
        )
        host.rootView = AnyView(programWorkColumnHost(model: model, lane: .done))
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)

        let updatedContainer = try XCTUnwrap(findScrollContainer(in: host))
        let updatedViews = try scrollViews(in: updatedContainer)
        XCTAssertEqual(updatedViews.scrollView.documentVisibleRect.minY, 220, accuracy: 0.5)
    }

    func testStableProgramWorkColumnsManualScrollInputsReachCompleteFirstCards() throws {
        let model = ProgramBoardViewModel()
        model.snapshot = programDashboardSnapshot(
            backlogItems: laneTickets(prefix: "RR-BACKLOG", status: Ticket.Status.backlog.rawValue, count: 24),
            doneItems: laneTickets(prefix: "RR-DONE", status: Ticket.Status.done.rawValue, count: 220)
        )

        let host = NSHostingView(rootView:
            HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                ProgramWorkColumnPanel(
                    model: model,
                    lane: .backlog,
                    showsProjectContext: true,
                    theme: nil,
                    canCreate: true,
                    onCreate: {},
                    onDrop: { _, _, _ in }
                )
                ProgramWorkColumnPanel(
                    model: model,
                    lane: .done,
                    showsProjectContext: true,
                    theme: nil,
                    canCreate: true,
                    onCreate: {},
                    onDrop: { _, _, _ in }
                )
            }
            .frame(width: 560, height: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
            .coordinateSpace(name: "programBoard")
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(host, width: 560, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let containers = findScrollContainers(in: host)
        XCTAssertEqual(containers.count, 2)

        try assertManualScrollInputsReturnFirstCardToTop(
            in: containers[0],
            window: window
        )
        try assertManualScrollInputsReturnFirstCardToTop(
            in: containers[1],
            window: window
        )
    }

    func testOnlyEditableItemsOfferDetailEditControls() {
        let backlogItem = programWorkItem(
            ticketID: "RR-BACKLOG-1",
            title: "Editable backlog ticket",
            status: Ticket.Status.backlog.rawValue
        )
        let doneItem = programWorkItem(
            ticketID: "RR-DONE-1",
            title: "Read-only done ticket",
            status: Ticket.Status.done.rawValue
        )

        XCTAssertTrue(backlogItem.showsProgramBoardEditButton)
        XCTAssertFalse(doneItem.showsProgramBoardEditButton)
    }

    func testCardDragLayerReportsHoverAndDoesNotReserveAnEditHitArea() throws {
        let eventView = ProgramWorkCardDragEventView()
        eventView.frame = CGRect(x: 0, y: 0, width: 220, height: 120)
        let editAreaPoint = CGPoint(x: 200, y: 20)
        var hoverStates: [Bool] = []
        eventView.onHoverChange = { hoverStates.append($0) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        eventView.mouseEntered(with: event)
        eventView.mouseExited(with: event)
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true, false])

        XCTAssertTrue(eventView.hitTest(editAreaPoint) === eventView)
    }

    func testCardDragLayerKeepsHoverAcrossTrackingReplacementAndClearsOnIdentityAndDetachment() {
        let eventView = ProgramWorkCardDragEventView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var hoverStates: [Bool] = []
        eventView.onHoverChange = { hoverStates.append($0) }
        eventView.interactionID = "all|Backlog|RR-1"
        eventView.pointerLocationOverride = CGPoint(x: 110, y: 60)
        window.contentView = eventView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        eventView.reconcilePointerContainment()
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true])

        eventView.updateTrackingAreas()
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true])

        eventView.interactionID = "all|Backlog|RR-2"
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true, false])
        eventView.reconcilePointerContainment()
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true, false, true])

        eventView.canDrag = true
        XCTAssertEqual(eventView.cursorPresentation, .openHand)
        eventView.canDrag = false
        XCTAssertEqual(eventView.cursorPresentation, .arrow)
        XCTAssertTrue(eventView.isPointerInside)

        window.contentView = NSView()
        drainMainQueue()
        XCTAssertEqual(hoverStates, [true, false, true, false])
        XCTAssertFalse(eventView.isPointerInside)
    }

    func testCardDragLayerCancelsActiveDragWithoutLeavingPointerState() throws {
        let eventView = ProgramWorkCardDragEventView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = eventView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        eventView.canDrag = true
        eventView.windowLocationToBoardLocation = { $0 }
        var changeCount = 0
        var endCount = 0
        var cancelCount = 0
        eventView.onChanged = { _, _, _ in changeCount += 1 }
        eventView.onEnded = { endCount += 1 }
        eventView.onCancelled = { cancelCount += 1 }
        let start = CGPoint(x: 40, y: 40)

        sendMouse(.leftMouseDown, at: start, to: eventView, in: window)
        sendMouse(
            .leftMouseDragged,
            at: CGPoint(x: start.x + ProgramWorkCardDragEventView.dragThreshold + 1, y: start.y),
            to: eventView,
            in: window
        )
        XCTAssertTrue(eventView.isDragActive)
        XCTAssertEqual(changeCount, 1)

        eventView.cancelOperation(nil)
        drainMainQueue()

        XCTAssertFalse(eventView.isDragActive)
        XCTAssertFalse(eventView.isPointerInside)
        XCTAssertEqual(endCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testCardDragLayerKeepsClickSelectionBelowDragThreshold() {
        let eventView = ProgramWorkCardDragEventView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = eventView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        eventView.canDrag = true
        eventView.windowLocationToBoardLocation = { $0 }
        var selectCount = 0
        var endCount = 0
        eventView.onSelect = { selectCount += 1 }
        eventView.onEnded = { endCount += 1 }
        let start = CGPoint(x: 40, y: 40)

        sendMouse(.leftMouseDown, at: start, to: eventView, in: window)
        sendMouse(
            .leftMouseDragged,
            at: CGPoint(x: start.x + ProgramWorkCardDragEventView.dragThreshold - 1, y: start.y),
            to: eventView,
            in: window
        )
        sendMouse(.leftMouseUp, at: start, to: eventView, in: window)

        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(endCount, 0)
        XCTAssertFalse(eventView.isDragActive)
    }

    func testProgramWorkCardCursorPresentationMapsEligibilityAndDragState() {
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(canDrag: false, isDragging: false),
            .arrow
        )
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(canDrag: false, isDragging: true),
            .arrow
        )
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(canDrag: true, isDragging: false),
            .openHand
        )
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(canDrag: true, isDragging: true),
            .closedHand
        )
        XCTAssertTrue(ProgramWorkCardCursorPresentation.arrow.cursor === NSCursor.arrow)
        XCTAssertTrue(ProgramWorkCardCursorPresentation.openHand.cursor === NSCursor.openHand)
        XCTAssertTrue(ProgramWorkCardCursorPresentation.closedHand.cursor === NSCursor.closedHand)

        let activeWorker = ProgramStatusItem(
            project: ProgramStatusProject(name: "relay-runner", path: "/repo/relay-runner"),
            ticketID: "RR-ACTIVE",
            title: "Active worker",
            status: Ticket.Status.inProgress.rawValue,
            priority: Ticket.Priority.medium.rawValue,
            runState: "active"
        )
        let awaitingMerge = ProgramStatusItem(
            project: ProgramStatusProject(name: "relay-runner", path: "/repo/relay-runner"),
            ticketID: "RR-MERGE",
            title: "Awaiting merge",
            status: Ticket.Status.inProgress.rawValue,
            priority: Ticket.Priority.medium.rawValue,
            runState: "awaiting_merge"
        )
        XCTAssertFalse(activeWorker.isProgramBoardDraggable)
        XCTAssertFalse(awaitingMerge.isProgramBoardDraggable)
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(
                canDrag: activeWorker.isProgramBoardDraggable,
                isDragging: false
            ),
            .arrow
        )
        XCTAssertEqual(
            ProgramWorkCardCursorPresentation.resolve(
                canDrag: awaitingMerge.isProgramBoardDraggable,
                isDragging: false
            ),
            .arrow
        )
    }

    func testMountedProgramWorkspaceKeepsExactHitIndexAcrossScrollAndSnapshot() throws {
        let model = ProgramBoardViewModel()
        let initialItems = laneTickets(
            prefix: "RR-HOVER",
            status: Ticket.Status.backlog.rawValue,
            count: 12
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: initialItems,
            doneItems: []
        )
        let host = NSHostingView(rootView: AnyView(
            programWorkColumnHost(model: model, lane: .backlog)
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 270, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let backlogContainer = try XCTUnwrap(findScrollContainer(in: host))
        let scrollViews = try scrollViews(in: backlogContainer)
        var cards = programWorkCardViews(in: backlogContainer)
        XCTAssertGreaterThan(cards.count, 2)
        let hitLocations = mountedCardHitLocations(in: window)
        XCTAssertGreaterThan(hitLocations.count, 1)

        XCTAssertEqual(
            Set(hitLocations.map { $0.card.interactionID }).count,
            hitLocations.count
        )

        scrollViews.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scrollViews.scrollView.reflectScrolledClipView(scrollViews.scrollView.contentView)
        drainMainQueue()
        let scrolledHitLocations = mountedCardHitLocations(in: window)
        XCTAssertGreaterThan(scrolledHitLocations.count, 1)
        XCTAssertEqual(
            Set(scrolledHitLocations.map { $0.card.interactionID }).count,
            scrolledHitLocations.count
        )

        let oldCards = cards
        model.snapshot = programDashboardSnapshot(
            backlogItems: laneTickets(
                prefix: "RR-REFRESHED",
                status: Ticket.Status.backlog.rawValue,
                count: 8
            ),
            doneItems: []
        )
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        cards = programWorkCardViews(in: try XCTUnwrap(findScrollContainer(in: host)))
        XCTAssertTrue(oldCards.allSatisfy { oldCard in
            !oldCard.isPointerInside || cards.contains { $0 === oldCard }
        })
        let refreshedHitLocations = mountedCardHitLocations(in: window)
        XCTAssertGreaterThan(refreshedHitLocations.count, 1)
        XCTAssertTrue(refreshedHitLocations.allSatisfy {
            $0.card.interactionID.contains("RR-REFRESHED")
        })
    }

    func testMountedBoardPanelDeliversRealPointerEventsToFirstBacklogCard() throws {
        let model = ProgramBoardViewModel()
        let backlogItems = laneTickets(
            prefix: "RR-PANEL-POINTER",
            status: Ticket.Status.backlog.rawValue,
            count: 4
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: backlogItems,
            doneItems: []
        )
        let workspace = WorkspaceViewModel()
        workspace.configure(
            showsWorkTab: true,
            showsTerminalTab: false,
            showsSettingsTab: false,
            initialTab: .work
        )
        let host = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            workspace: workspace,
            settingsContent: nil,
            terminalContent: { _ in nil },
            onDismiss: {},
            onWorkspaceTabChange: { _ in },
            onRefresh: {},
            onStartSession: {},
            onEndSession: {},
            onCreateStart: { _ in },
            onCreateCommit: { _ in },
            onCreateCancel: {},
            onEditStart: { _ in },
            onEditCommit: { _ in },
            onEditCancel: {},
            onDelete: { _ in },
            onDrop: { _, _, _ in }
        ))
        let panelFrame = CGRect(x: 0, y: 0, width: 1_512, height: 800)
        let panel = BoardOverlayPanel()
        panel.setFrame(panelFrame, display: false)
        host.frame = CGRect(origin: .zero, size: panelFrame.size)
        let revealContainer = BoardRevealContainerView(
            frame: CGRect(origin: .zero, size: panelFrame.size),
            contentView: host,
            displayGeometry: NotchStatusDisplayGeometry(screenFrame: panelFrame),
            startsLoading: false
        )
        panel.contentView = revealContainer
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        revealContainer.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let revealed = expectation(description: "Workspace content revealed")
        revealContainer.animateReveal {
            revealed.fulfill()
        }
        wait(for: [revealed], timeout: 5)
        drainMainQueue()

        let cards = programWorkCardViews(in: host)
        let firstItem = try XCTUnwrap(model.ticketItems(in: .backlog).first)
        let firstCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(firstItem.id)"
        })
        let secondItem = model.ticketItems(in: .backlog)[1]
        let secondCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(secondItem.id)"
        })
        let container = try XCTUnwrap(scrollContainer(owning: firstCard))
        let center = firstCard.convert(
            CGPoint(x: firstCard.bounds.midX, y: firstCard.bounds.midY),
            to: nil
        )
        let secondCenter = secondCard.convert(
            CGPoint(x: secondCard.bounds.midX, y: secondCard.bounds.midY),
            to: nil
        )
        let contentView = try XCTUnwrap(panel.contentView)
        let contentPoint = contentView.convert(center, from: nil)
        let views = try scrollViews(in: container)
        let containerPoint = container.convert(contentPoint, from: contentView)
        let clipPoint = views.scrollView.contentView.convert(containerPoint, from: container)
        let documentPoint = views.documentView.convert(clipPoint, from: views.scrollView.contentView)
        let screenPoint = panel.convertPoint(toScreen: center)

        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertTrue(mountedProgramWorkCardHit(at: contentPoint, in: contentView) === firstCard)
        XCTAssertEqual(panel.convertPoint(fromScreen: screenPoint).x, center.x, accuracy: 0.5)
        XCTAssertEqual(panel.convertPoint(fromScreen: screenPoint).y, center.y, accuracy: 0.5)
        XCTAssertTrue(firstCard.convert(firstCard.bounds, to: views.documentView).contains(documentPoint))
        XCTAssertEqual(firstCard.cursorPresentation, .openHand)

        let mouseMoved = try XCTUnwrap(mouseEvent(.mouseMoved, at: center, in: panel))
        let mouseDown = try XCTUnwrap(mouseEvent(.leftMouseDown, at: center, in: panel))
        let mouseUp = try XCTUnwrap(mouseEvent(.leftMouseUp, at: center, in: panel))
        XCTAssertTrue(firstCard.acceptsFirstMouse(for: mouseDown))

        var selectionCount = 0
        firstCard.onSelect = {
            selectionCount += 1
            model.selectTicket(firstItem)
        }
        NSApp.sendEvent(mouseMoved)
        XCTAssertTrue(firstCard.isPointerInside)
        NSApp.sendEvent(mouseDown)
        NSApp.sendEvent(mouseUp)
        drainMainQueue()

        XCTAssertEqual(selectionCount, 1)
        XCTAssertEqual(model.selectedTicketDetail?.item.id, firstItem.id)

        let secondMouseMoved = try XCTUnwrap(mouseEvent(.mouseMoved, at: secondCenter, in: panel))
        NSApp.sendEvent(secondMouseMoved)
        XCTAssertFalse(firstCard.isPointerInside)
        XCTAssertTrue(secondCard.isPointerInside)

        var dragChangeCount = 0
        var dragEndCount = 0
        firstCard.windowLocationToBoardLocation = { $0 }
        firstCard.onChanged = { _, _, _ in dragChangeCount += 1 }
        firstCard.onEnded = { dragEndCount += 1 }
        let dragPoint = CGPoint(
            x: center.x + firstCard.bounds.width,
            y: center.y
        )
        let dragContentPoint = contentView.convert(dragPoint, from: nil)
        XCTAssertNil(mountedProgramWorkCardHit(at: dragContentPoint, in: contentView))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDown, at: center, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDragged, at: dragPoint, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseUp, at: dragPoint, in: panel)))

        XCTAssertEqual(dragChangeCount, 1)
        XCTAssertEqual(dragEndCount, 1)
        XCTAssertFalse(firstCard.isDragActive)

        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.mouseMoved, at: dragPoint, in: panel)))
        drainMainQueue()
        XCTAssertTrue(programWorkCardViews(in: host).allSatisfy { !$0.isPointerInside })
    }

    func testMountedBoardPanelKeepsEveryVisibleBacklogCardAsItsDragSource() throws {
        let model = ProgramBoardViewModel()
        let backlogItems = laneTickets(
            prefix: "RR-PANEL-IDENTITY",
            status: Ticket.Status.backlog.rawValue,
            count: 12
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: backlogItems,
            doneItems: []
        )
        let workspace = WorkspaceViewModel()
        workspace.configure(
            showsWorkTab: true,
            showsTerminalTab: false,
            showsSettingsTab: false,
            initialTab: .work
        )
        var drops: [(ProgramStatusItem, ProgramBoardLane, ProgramBoardLane)] = []
        let host = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            workspace: workspace,
            settingsContent: nil,
            terminalContent: { _ in nil },
            onDismiss: {},
            onWorkspaceTabChange: { _ in },
            onRefresh: {},
            onStartSession: {},
            onEndSession: {},
            onCreateStart: { _ in },
            onCreateCommit: { _ in },
            onCreateCancel: {},
            onEditStart: { _ in },
            onEditCommit: { _ in },
            onEditCancel: {},
            onDelete: { _ in },
            onDrop: { drops.append(($0, $1, $2)) }
        ))
        let panelFrame = CGRect(x: 0, y: 0, width: 1_512, height: 800)
        let panel = BoardOverlayPanel()
        panel.setFrame(panelFrame, display: false)
        host.frame = CGRect(origin: .zero, size: panelFrame.size)
        let revealContainer = BoardRevealContainerView(
            frame: CGRect(origin: .zero, size: panelFrame.size),
            contentView: host,
            displayGeometry: NotchStatusDisplayGeometry(screenFrame: panelFrame),
            startsLoading: false
        )
        panel.contentView = revealContainer
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        revealContainer.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let revealed = expectation(description: "Workspace content revealed")
        revealContainer.animateReveal {
            revealed.fulfill()
        }
        wait(for: [revealed], timeout: 5)
        drainMainQueue()

        let cardsByID = Dictionary(
            uniqueKeysWithValues: programWorkCardViews(in: host).map { ($0.interactionID, $0) }
        )
        let mountedCards = try model.ticketItems(in: .backlog).map { item in
            (
                item,
                try XCTUnwrap(cardsByID["all|Backlog|\(item.id)"])
            )
        }
        XCTAssertEqual(mountedCards.count, backlogItems.count)

        let boardFrame = try XCTUnwrap(model.boardFrameInWindow)
        let queuedFrame = try XCTUnwrap(model.columnFrames[.ready])
        let queuedBoardTarget = CGPoint(
            x: queuedFrame.midX,
            y: queuedFrame.minY + min(160, queuedFrame.height / 2)
        )
        let queuedWindowTarget = CGPoint(
            x: boardFrame.minX + queuedBoardTarget.x,
            y: boardFrame.maxY - queuedBoardTarget.y
        )

        for (item, card) in mountedCards {
            let scrollView = try XCTUnwrap(card.enclosingScrollView)
            let documentView = try XCTUnwrap(scrollView.documentView)
            let documentFrame = card.convert(card.bounds, to: documentView)
            let maxOffset = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: CGPoint(
                x: 0,
                y: min(max(documentFrame.midY - scrollView.contentView.bounds.height / 2, 0), maxOffset)
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            drainMainQueue()
            let visibleFrame = card.convert(card.bounds, to: scrollView.contentView)
                .intersection(scrollView.contentView.bounds)
            XCTAssertGreaterThan(visibleFrame.height, 10)
            let start = scrollView.contentView.convert(
                CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
                to: nil
            )

            NSApp.sendEvent(try XCTUnwrap(mouseEvent(.mouseMoved, at: start, in: panel)))
            XCTAssertTrue(card.isPointerInside, "Hover routed to a different card than \(item.id)")
            drainMainQueue()
            let currentCard = try XCTUnwrap(programWorkCardViews(in: host).first {
                $0.interactionID == "all|Backlog|\(item.id)"
            })
            let contentView = try XCTUnwrap(panel.contentView)
            XCTAssertTrue(
                mountedProgramWorkCardHit(
                    at: contentView.convert(start, from: nil),
                    in: contentView
                ) === currentCard
            )

            NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDown, at: start, in: panel)))
            NSApp.sendEvent(try XCTUnwrap(mouseEvent(
                .leftMouseDragged,
                at: CGPoint(
                    x: start.x + ProgramWorkCardDragEventView.dragThreshold + 1,
                    y: start.y
                ),
                in: panel
            )))
            drainMainQueue()
            XCTAssertEqual(model.dragItemID, item.id, "Pointer-down captured a different visible card")

            NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDragged, at: queuedWindowTarget, in: panel)))
            NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseUp, at: queuedWindowTarget, in: panel)))
            drainMainQueue()
            XCTAssertEqual(drops.last?.0.id, item.id)
            XCTAssertNil(model.dragItemID)
        }
    }

    func testMountedBoardPanelCancelsStaleValidDragBeforeNewGestureAndOrderOut() throws {
        let model = ProgramBoardViewModel()
        let staleItem = programWorkItem(
            ticketID: "VQ-1",
            title: "Stale captured ticket",
            status: Ticket.Status.backlog.rawValue
        )
        let intendedItem = programWorkItem(
            ticketID: "RR-176",
            title: "Intended dragged ticket",
            status: Ticket.Status.backlog.rawValue
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: [staleItem, intendedItem],
            doneItems: []
        )
        let workspace = WorkspaceViewModel()
        workspace.configure(
            showsWorkTab: true,
            showsTerminalTab: false,
            showsSettingsTab: false,
            initialTab: .work
        )
        var drops: [(ProgramStatusItem, ProgramBoardLane, ProgramBoardLane)] = []
        let host = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            workspace: workspace,
            settingsContent: nil,
            terminalContent: { _ in nil },
            onDismiss: {},
            onWorkspaceTabChange: { _ in },
            onRefresh: {},
            onStartSession: {},
            onEndSession: {},
            onCreateStart: { _ in },
            onCreateCommit: { _ in },
            onCreateCancel: {},
            onEditStart: { _ in },
            onEditCommit: { _ in },
            onEditCancel: {},
            onDelete: { _ in },
            onDrop: { drops.append(($0, $1, $2)) }
        ))
        let panelFrame = CGRect(x: 0, y: 0, width: 1_512, height: 800)
        let panel = BoardOverlayPanel()
        panel.setFrame(panelFrame, display: false)
        host.frame = CGRect(origin: .zero, size: panelFrame.size)
        let revealContainer = BoardRevealContainerView(
            frame: CGRect(origin: .zero, size: panelFrame.size),
            contentView: host,
            displayGeometry: NotchStatusDisplayGeometry(screenFrame: panelFrame),
            startsLoading: false
        )
        panel.contentView = revealContainer
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        revealContainer.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let revealed = expectation(description: "Workspace content revealed")
        revealContainer.animateReveal {
            revealed.fulfill()
        }
        wait(for: [revealed], timeout: 5)
        drainMainQueue()

        let cards = programWorkCardViews(in: host)
        let staleCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(staleItem.id)"
        })
        let intendedCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(intendedItem.id)"
        })
        let staleStart = staleCard.convert(
            CGPoint(x: staleCard.bounds.midX, y: staleCard.bounds.midY),
            to: nil
        )
        let intendedStart = intendedCard.convert(
            CGPoint(x: intendedCard.bounds.midX, y: intendedCard.bounds.midY),
            to: nil
        )
        let boardFrame = try XCTUnwrap(model.boardFrameInWindow)
        let queuedFrame = try XCTUnwrap(model.columnFrames[.ready])
        let queuedBoardTarget = CGPoint(
            x: queuedFrame.midX,
            y: queuedFrame.minY + min(160, queuedFrame.height / 2)
        )
        let queuedWindowTarget = CGPoint(
            x: boardFrame.minX + queuedBoardTarget.x,
            y: boardFrame.maxY - queuedBoardTarget.y
        )

        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.mouseMoved, at: staleStart, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDown, at: staleStart, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: staleStart.x + ProgramWorkCardDragEventView.dragThreshold + 1, y: staleStart.y),
            in: panel
        )))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDragged, at: queuedWindowTarget, in: panel)))
        drainMainQueue()

        XCTAssertEqual(model.dragItemID, staleItem.id)
        XCTAssertEqual(model.dragTarget, ProgramBoardDropTarget(lane: .ready, isValid: true))

        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.mouseMoved, at: intendedStart, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDown, at: intendedStart, in: panel)))
        drainMainQueue()

        XCTAssertTrue(drops.isEmpty)
        XCTAssertNil(model.dragItemID)

        NSApp.sendEvent(try XCTUnwrap(mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: intendedStart.x + ProgramWorkCardDragEventView.dragThreshold + 1, y: intendedStart.y),
            in: panel
        )))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDragged, at: queuedWindowTarget, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseUp, at: queuedWindowTarget, in: panel)))
        drainMainQueue()

        XCTAssertEqual(
            drops.map { [$0.0.id, $0.1.id, $0.2.id] },
            [[intendedItem.id, "Backlog", "Queued"]]
        )
        XCTAssertNil(model.dragItemID)

        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.mouseMoved, at: staleStart, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDown, at: staleStart, in: panel)))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: staleStart.x + ProgramWorkCardDragEventView.dragThreshold + 1, y: staleStart.y),
            in: panel
        )))
        NSApp.sendEvent(try XCTUnwrap(mouseEvent(.leftMouseDragged, at: queuedWindowTarget, in: panel)))
        drainMainQueue()
        XCTAssertEqual(model.dragItemID, staleItem.id)
        XCTAssertEqual(model.dragTarget, ProgramBoardDropTarget(lane: .ready, isValid: true))

        panel.orderOut(nil)
        drainMainQueue()

        XCTAssertEqual(
            drops.map { [$0.0.id, $0.1.id, $0.2.id] },
            [[intendedItem.id, "Backlog", "Queued"]]
        )
        XCTAssertNil(model.dragItemID)
        XCTAssertFalse(staleCard.isDragActive)
        XCTAssertTrue(programWorkCardViews(in: host).allSatisfy { !$0.isPointerInside })
    }

    func testMountedProgramWorkspaceFirstBacklogCardOwnsItsVisibleHitTarget() throws {
        let model = ProgramBoardViewModel()
        let backlogItems = laneTickets(
            prefix: "RR-FIRST-HIT",
            status: Ticket.Status.backlog.rawValue,
            count: 8
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: backlogItems,
            doneItems: []
        )
        let host = NSHostingView(rootView: AnyView(
            programWorkColumnHost(model: model, lane: .backlog)
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 270, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let backlogContainer = try XCTUnwrap(findScrollContainer(in: host))
        let cards = programWorkCardViews(in: backlogContainer)
        let orderedItems = model.ticketItems(in: .backlog)
        let firstCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(orderedItems[0].id)"
        })
        let secondCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(orderedItems[1].id)"
        })
        let firstInteractionID = firstCard.interactionID
        let secondInteractionID = secondCard.interactionID
        XCTAssertGreaterThan(firstCard.bounds.height, 20)
        XCTAssertGreaterThan(secondCard.bounds.height, 20)

        let firstHitLocations = mountedHitLocations(for: firstCard, in: window)
        let secondHitLocations = mountedHitLocations(for: secondCard, in: window)
        XCTAssertGreaterThanOrEqual(firstHitLocations.count, Int(firstCard.bounds.height) - 8)
        XCTAssertGreaterThanOrEqual(secondHitLocations.count, Int(secondCard.bounds.height) - 8)
        XCTAssertEqual(firstCard.cursorPresentation, .openHand)
        XCTAssertEqual(secondCard.cursorPresentation, .openHand)

        for fraction in [CGFloat(0.05), 0.5, 0.95] {
            let firstLocation = firstHitLocations[
                min(firstHitLocations.count - 1, Int(CGFloat(firstHitLocations.count) * fraction))
            ]
            let contentView = try XCTUnwrap(window.contentView)
            let currentFirstCard = try XCTUnwrap(mountedProgramWorkCardHit(
                at: contentView.convert(firstLocation, from: nil),
                in: contentView
            ))
            XCTAssertEqual(currentFirstCard.interactionID, firstInteractionID)

            let secondLocation = secondHitLocations[
                min(secondHitLocations.count - 1, Int(CGFloat(secondHitLocations.count) * fraction))
            ]
            let currentSecondCard = try XCTUnwrap(mountedProgramWorkCardHit(
                at: contentView.convert(secondLocation, from: nil),
                in: contentView
            ))
            XCTAssertEqual(currentSecondCard.interactionID, secondInteractionID)
        }

        let contentView = try XCTUnwrap(window.contentView)
        let firstContentLocation = contentView.convert(
            try XCTUnwrap(firstHitLocations.first),
            from: nil
        )
        let leadingStripLocation = CGPoint(
            x: firstContentLocation.x,
            y: firstContentLocation.y - 2
        )
        XCTAssertNil(mountedProgramWorkCardHit(at: leadingStripLocation, in: contentView))

        model.dragTarget = ProgramBoardDropTarget(lane: .backlog, isValid: true)
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()
        XCTAssertNil(mountedProgramWorkCardHit(at: leadingStripLocation, in: contentView))
        model.dragTarget = nil

        let views = try scrollViews(in: backlogContainer)
        views.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)
        drainMainQueue()
        views.scrollView.contentView.scroll(to: .zero)
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)
        drainMainQueue()

        let returnedCards = programWorkCardViews(in: backlogContainer)
        let returnedFirst = try XCTUnwrap(returnedCards.first {
            $0.interactionID == "all|Backlog|\(orderedItems[0].id)"
        })
        XCTAssertGreaterThanOrEqual(
            mountedHitLocations(for: returnedFirst, in: window).count,
            Int(returnedFirst.bounds.height) - 8
        )

        let replacementItems = laneTickets(
            prefix: "RR-REPLACED-FIRST-HIT",
            status: Ticket.Status.backlog.rawValue,
            count: 4
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: replacementItems,
            doneItems: []
        )
        host.rootView = AnyView(programWorkColumnHost(model: model, lane: .backlog))
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let replacementFirstItem = try XCTUnwrap(model.ticketItems(in: .backlog).first)
        let replacementContainer = try XCTUnwrap(findScrollContainer(in: host))
        let replacementCards = programWorkCardViews(in: replacementContainer)
        let replacementFirst = try XCTUnwrap(replacementCards.first {
            $0.interactionID == "all|Backlog|\(replacementFirstItem.id)"
        })
        XCTAssertGreaterThanOrEqual(
            mountedHitLocations(for: replacementFirst, in: window).count,
            Int(replacementFirst.bounds.height) - 8
        )

        model.selectProject(path: "/repo/relay-runner")
        host.rootView = AnyView(programWorkColumnHost(model: model, lane: .backlog))
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()
        let scopedCards = programWorkCardViews(in: try XCTUnwrap(findScrollContainer(in: host)))
        let scopedFirst = try XCTUnwrap(scopedCards.first {
            $0.interactionID == "/repo/relay-runner|Backlog|\(replacementFirstItem.id)"
        })
        XCTAssertGreaterThanOrEqual(
            mountedHitLocations(for: scopedFirst, in: window).count,
            Int(scopedFirst.bounds.height) - 8
        )
    }

    func testMountedProgramWorkspaceNonDraggableFirstCardKeepsClickAndArrowCursor() throws {
        let model = ProgramBoardViewModel()
        let activeItem = ProgramStatusItem(
            project: ProgramStatusProject(name: "relay-runner", path: "/repo/relay-runner"),
            ticketID: "RR-NONDRAG-900",
            title: "Active first ticket cannot be dragged",
            status: Ticket.Status.backlog.rawValue,
            priority: Ticket.Priority.high.rawValue,
            runState: "active"
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: [
                activeItem,
                programWorkItem(
                    ticketID: "RR-NONDRAG-899",
                    title: "Draggable second ticket",
                    status: Ticket.Status.backlog.rawValue
                ),
            ],
            doneItems: []
        )
        let host = NSHostingView(rootView: AnyView(
            programWorkColumnHost(model: model, lane: .backlog)
        ))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 270, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(host, width: 270, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let container = try XCTUnwrap(findScrollContainer(in: host))
        let cards = programWorkCardViews(in: container)
        let firstCard = try XCTUnwrap(cards.first {
            $0.interactionID == "all|Backlog|\(activeItem.id)"
        })
        XCTAssertFalse(activeItem.isProgramBoardDraggable)
        XCTAssertEqual(firstCard.cursorPresentation, .arrow)
        let hitLocations = mountedHitLocations(for: firstCard, in: window)
        XCTAssertGreaterThanOrEqual(hitLocations.count, Int(firstCard.bounds.height) - 8)

        let start = hitLocations[hitLocations.count / 2]
        firstCard.windowLocationToBoardLocation = { $0 }
        var dragChangeCount = 0
        firstCard.onChanged = { _, _, _ in dragChangeCount += 1 }
        sendMouse(.leftMouseDown, at: start, to: firstCard, in: window)
        sendMouse(
            .leftMouseDragged,
            at: CGPoint(x: start.x + ProgramWorkCardDragEventView.dragThreshold + 4, y: start.y),
            to: firstCard,
            in: window
        )
        sendMouse(.leftMouseUp, at: start, to: firstCard, in: window)
        drainMainQueue()

        XCTAssertEqual(dragChangeCount, 0)
        XCTAssertFalse(firstCard.isDragActive)
        XCTAssertNil(model.dragItemID)
        XCTAssertEqual(model.selectedTicketDetail?.item.id, activeItem.id)
    }

    func testProgramWorkCardDragStartsThroughMountedScrollHierarchy() throws {
        let model = ProgramBoardViewModel()
        let backlogItem = programWorkItem(
            ticketID: "RR-231",
            title: "Mounted backlog ticket",
            status: Ticket.Status.backlog.rawValue
        )
        model.snapshot = programDashboardSnapshot(
            backlogItems: [backlogItem],
            doneItems: []
        )

        var drops: [(ProgramStatusItem, ProgramBoardLane, ProgramBoardLane)] = []
        let host = NSHostingView(rootView:
            HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                ProgramWorkColumnPanel(
                    model: model,
                    lane: .backlog,
                    showsProjectContext: true,
                    theme: nil,
                    canCreate: true,
                    onCreate: {},
                    onDrop: { drops.append(($0, $1, $2)) }
                )
                ProgramWorkColumnPanel(
                    model: model,
                    lane: .done,
                    showsProjectContext: true,
                    theme: nil,
                    canCreate: true,
                    onCreate: {},
                    onDrop: { drops.append(($0, $1, $2)) }
                )
            }
            .frame(width: 560, height: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
            .coordinateSpace(name: "programBoard")
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        layout(host, width: 560, height: BoardSurfaceLayout.columnHeight)
        drainMainQueue()

        let columnWidth = (CGFloat(560) - BoardSurfaceLayout.columnSpacing) / 2
        model.boardFrameInWindow = CGRect(x: 0, y: 0, width: 560, height: BoardSurfaceLayout.columnHeight)
        model.columnFrames = [
            .backlog: CGRect(x: 0, y: 0, width: columnWidth, height: BoardSurfaceLayout.columnHeight),
            .done: CGRect(
                x: columnWidth + BoardSurfaceLayout.columnSpacing,
                y: 0,
                width: columnWidth,
                height: BoardSurfaceLayout.columnHeight
            ),
        ]
        let backlogFrame = try XCTUnwrap(model.columnFrames[.backlog])
        let doneFrame = try XCTUnwrap(model.columnFrames[.done])
        let backlogContainer = try XCTUnwrap(findScrollContainers(in: host).first)
        let backlogCard = try XCTUnwrap(programWorkCardViews(in: backlogContainer).first {
            $0.interactionID == "all|Backlog|\(backlogItem.id)"
        })
        let backlogHitLocations = mountedHitLocations(
            for: backlogCard,
            in: window,
            contentX: backlogFrame.minX + 80
        )
        let start = backlogHitLocations[backlogHitLocations.count / 2]
        let boardStart = try XCTUnwrap(model.boardLocation(fromWindowLocation: start))
        let overThreshold = CGPoint(x: start.x + 12, y: start.y)
        let boardDoneTarget = CGPoint(x: doneFrame.midX, y: max(doneFrame.minY + 160, boardStart.y))
        let doneTarget = windowLocation(
            forBoardLocation: boardDoneTarget,
            windowHeight: BoardSurfaceLayout.columnHeight
        )
        let contentView = try XCTUnwrap(window.contentView)
        let contentStart = contentView.convert(start, from: nil)
        let eventTarget = try XCTUnwrap(
            mountedProgramWorkCardHit(at: contentStart, in: contentView)
        )
        XCTAssertTrue(eventTarget === backlogCard)

        sendMouse(.leftMouseDown, at: start, to: eventTarget, in: window)
        sendMouse(.leftMouseDragged, at: CGPoint(x: start.x + 3, y: start.y), to: eventTarget, in: window)
        drainMainQueue()
        XCTAssertNil(model.dragItemID)

        sendMouse(.leftMouseDragged, at: overThreshold, to: eventTarget, in: window)
        drainMainQueue()
        XCTAssertEqual(model.dragItemID, backlogItem.id)
        XCTAssertNotNil(model.dragPreview)

        sendMouse(.leftMouseDragged, at: doneTarget, to: eventTarget, in: window)
        drainMainQueue()
        XCTAssertEqual(model.dragTarget, ProgramBoardDropTarget(lane: .done, isValid: true))

        sendMouse(.leftMouseUp, at: doneTarget, to: eventTarget, in: window)
        drainMainQueue()
        XCTAssertEqual(drops.map { [$0.0.id, $0.1.id, $0.2.id] }, [[backlogItem.id, "Backlog", "Done"]])
        XCTAssertNil(model.dragItemID)
    }

    func testTicketDetailOmitsOpenWorkspaceAction() {
        let item = ProgramStatusItem(
            project: ProgramStatusProject(name: "Relay Runner", path: "/repo/relay-runner"),
            ticketID: "RR-214",
            title: "Scroll endpoints",
            status: Ticket.Status.inProgress.rawValue,
            priority: Ticket.Priority.high.rawValue
        )
        let detail = ProgramTicketDetail(
            item: item,
            identity: ProgramTicketIdentity(item: item),
            ticket: Ticket(
                id: "RR-214",
                title: "Scroll endpoints",
                status: .inProgress,
                priority: .high,
                dependsOn: [],
                runId: 306,
                canceled: false,
                order: 214,
                description: "Fix scrolling",
                body: """
                ## Description

                Fix scrolling

                ## Acceptance criteria

                - [ ] Reach the endpoints
                """
            ),
            ticketPath: "/repo/relay-runner/.orchestrator/RR-214.md",
            description: "Fix scrolling",
            acceptanceCriteria: "- [ ] Reach the endpoints",
            imageAttachments: [],
            unavailableMessage: nil
        )

        let host = NSHostingView(rootView:
            ProgramTicketDetailPanel(
                detail: detail,
                theme: nil,
                onClose: {},
                onEdit: {},
                onDelete: { _ in }
            )
        )
        host.frame = CGRect(x: 0, y: 0, width: 560, height: 633)
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(textValues(in: host).contains("Open Workspace"))
    }

    private func layout(_ container: BoardOverlayScrollContainer, width: CGFloat, height: CGFloat) {
        container.frame = CGRect(x: 0, y: 0, width: width, height: height)
        container.layout()
    }

    private func layout<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) {
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
    }

    private func scrollViews(in container: BoardOverlayScrollContainer) throws -> (
        scrollView: NSScrollView,
        documentView: NSView,
        hostingView: NSView
    ) {
        let scrollView = try XCTUnwrap(container.subviews.compactMap { $0 as? NSScrollView }.first)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let hostingView = try XCTUnwrap(findHostingView(in: documentView))
        return (scrollView, documentView, hostingView)
    }

    private func findHostingView(in view: NSView) -> BoardOverlayScrollHostingView? {
        if let hostingView = view as? BoardOverlayScrollHostingView {
            return hostingView
        }
        for subview in view.subviews {
            if let hostingView = findHostingView(in: subview) {
                return hostingView
            }
        }
        return nil
    }

    private func findScrollContainer(in view: NSView) -> BoardOverlayScrollContainer? {
        if let container = view as? BoardOverlayScrollContainer {
            return container
        }
        for subview in view.subviews {
            if let container = findScrollContainer(in: subview) {
                return container
            }
        }
        return nil
    }

    private func findScrollContainers(in view: NSView) -> [BoardOverlayScrollContainer] {
        let currentValue = (view as? BoardOverlayScrollContainer).map { [$0] } ?? []
        return currentValue + view.subviews.flatMap(findScrollContainers(in:))
    }

    private func thumbView(in container: BoardOverlayScrollContainer) -> NSView? {
        container.subviews.first { !($0 is NSScrollView) }
    }

    private func textValues(in view: NSView) -> [String] {
        let currentValue = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return currentValue + view.subviews.flatMap(textValues(in:))
    }

    private func findFirstCardMarker(in view: NSView) -> ProgramLaneFirstCardMarkerView? {
        if let marker = view as? ProgramLaneFirstCardMarkerView {
            return marker
        }
        for subview in view.subviews {
            if let match = findFirstCardMarker(in: subview) {
                return match
            }
        }
        return nil
    }

    private func assertManualScrollInputsReturnFirstCardToTop(
        in container: BoardOverlayScrollContainer,
        window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let views = try scrollViews(in: container)
        let wheelDelta: CGFloat = 64

        let preciseMaxOffset = scrollToBottom(views: views)
        XCTAssertGreaterThan(preciseMaxOffset, 200, file: file, line: line)
        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, preciseMaxOffset, accuracy: 0.5, file: file, line: line)
        sendScrollWheel(
            deltaY: wheelDelta,
            units: .pixel,
            repeats: Int(ceil(preciseMaxOffset / wheelDelta)) + 8,
            to: views.scrollView,
            in: window
        )
        drainMainQueue()
        try assertFirstCardAtTop(in: container, views: views, file: file, line: line)

        let wheelMaxOffset = scrollToBottom(views: views)
        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, wheelMaxOffset, accuracy: 0.5, file: file, line: line)
        sendScrollWheel(
            deltaY: wheelDelta,
            units: .line,
            repeats: Int(ceil(wheelMaxOffset / wheelDelta)) + 8,
            to: views.scrollView,
            in: window
        )
        drainMainQueue()
        try assertFirstCardAtTop(in: container, views: views, file: file, line: line)

        let keyboardMaxOffset = scrollToBottom(views: views)
        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, keyboardMaxOffset, accuracy: 0.5, file: file, line: line)
        sendHomeKey(to: views.scrollView, in: window)
        drainMainQueue()
        try assertFirstCardAtTop(in: container, views: views, file: file, line: line)
    }

    @discardableResult
    private func scrollToBottom(views: (scrollView: NSScrollView, documentView: NSView, hostingView: NSView)) -> CGFloat {
        let maxOffset = views.documentView.frame.height - views.scrollView.contentView.bounds.height
        views.scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
        views.scrollView.reflectScrolledClipView(views.scrollView.contentView)
        return maxOffset
    }

    private func assertFirstCardAtTop(
        in container: BoardOverlayScrollContainer,
        views: (scrollView: NSScrollView, documentView: NSView, hostingView: NSView),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(views.scrollView.documentVisibleRect.minY, 0, accuracy: 0.5, file: file, line: line)
        let thumb = try XCTUnwrap(thumbView(in: container), file: file, line: line)
        XCTAssertEqual(thumb.frame.minY, 6, accuracy: 0.5, file: file, line: line)

        let expectedFirstCardTop = ProgramBoardLayout.workScrollContentInsets.top
            + ProgramBoardLayout.dropIndicatorHeight
            + ProgramBoardLayout.dropIndicatorBottomPadding
        let firstCardView = try XCTUnwrap(
            programWorkCardViews(in: container).min { lhs, rhs in
                lhs.convert(lhs.bounds, to: views.documentView).minY <
                    rhs.convert(rhs.bounds, to: views.documentView).minY
            },
            file: file,
            line: line
        )
        let firstCardFrame = firstCardView.convert(firstCardView.bounds, to: views.scrollView.contentView)
        XCTAssertGreaterThanOrEqual(firstCardFrame.minY, expectedFirstCardTop, file: file, line: line)
        XCTAssertLessThanOrEqual(firstCardFrame.maxY, views.scrollView.contentView.bounds.height, file: file, line: line)
    }

    private func programWorkCardViews(in view: NSView) -> [ProgramWorkCardDragEventView] {
        let currentValue = (view as? ProgramWorkCardDragEventView).map { [$0] } ?? []
        return currentValue + view.subviews.flatMap(programWorkCardViews(in:))
    }

    private func scrollContainer(owning view: NSView) -> BoardOverlayScrollContainer? {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let container = candidate as? BoardOverlayScrollContainer {
                return container
            }
            ancestor = candidate.superview
        }
        return nil
    }

    private func mountedCardHitLocations(
        in window: NSWindow
    ) -> [(card: ProgramWorkCardDragEventView, location: CGPoint)] {
        var matches: [(ProgramWorkCardDragEventView, CGPoint)] = []
        for y in stride(from: CGFloat(0), through: window.contentView?.bounds.height ?? 0, by: 2) {
            let contentLocation = CGPoint(x: window.contentView?.bounds.midX ?? 0, y: y)
            var hitView = window.contentView?.hitTest(contentLocation)
            while let candidate = hitView {
                if let card = candidate as? ProgramWorkCardDragEventView {
                    if !matches.contains(where: { $0.0 === card }) {
                        let windowLocation = window.contentView?.convert(contentLocation, to: nil) ?? contentLocation
                        matches.append((card, windowLocation))
                    }
                    break
                }
                hitView = candidate.superview
            }
        }
        return matches
    }

    private func mountedHitLocations(
        for expectedCard: ProgramWorkCardDragEventView,
        in window: NSWindow,
        contentX: CGFloat? = nil
    ) -> [CGPoint] {
        guard let contentView = window.contentView else { return [] }
        return stride(from: CGFloat(0), through: contentView.bounds.height, by: 1).compactMap { y in
            let contentLocation = CGPoint(x: contentX ?? contentView.bounds.midX, y: y)
            return mountedProgramWorkCardHit(at: contentLocation, in: contentView) === expectedCard
                ? contentView.convert(contentLocation, to: nil)
                : nil
        }
    }

    private func mountedProgramWorkCardHit(
        at contentLocation: CGPoint,
        in contentView: NSView
    ) -> ProgramWorkCardDragEventView? {
        var hitView = contentView.hitTest(contentLocation)
        while let candidate = hitView {
            if let card = candidate as? ProgramWorkCardDragEventView {
                return card
            }
            hitView = candidate.superview
        }
        return nil
    }

    private func sendScrollWheel(
        deltaY: CGFloat,
        units: CGScrollEventUnit,
        repeats: Int,
        to scrollView: NSScrollView,
        in window: NSWindow
    ) {
        let location = scrollView.convert(
            CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )
        for _ in 0..<repeats {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: units,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: 0,
                wheel3: 0
            ) else {
                XCTFail("Failed to create scroll wheel event")
                return
            }
            cgEvent.location = location
            guard let event = NSEvent(cgEvent: cgEvent) else {
                XCTFail("Failed to create scroll wheel event")
                return
            }
            scrollView.scrollWheel(with: event)
        }
    }

    private func sendHomeKey(to scrollView: NSScrollView, in window: NSWindow) {
        window.makeFirstResponder(scrollView)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: scrollView.convert(
                CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                to: nil
            ),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{F729}",
            charactersIgnoringModifiers: "\u{F729}",
            isARepeat: false,
            keyCode: 115
        ) else {
            XCTFail("Failed to create home key event")
            return
        }
        scrollView.keyDown(with: event)
    }

    private func sendMouse(_ type: NSEvent.EventType, at location: CGPoint, to view: NSView, in window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: type == .leftMouseUp ? 0 : 1
        )
        if let event {
            switch type {
            case .leftMouseDown:
                view.mouseDown(with: event)
            case .leftMouseDragged:
                view.mouseDragged(with: event)
            case .leftMouseUp:
                view.mouseUp(with: event)
            default:
                break
            }
        }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private func windowLocation(forBoardLocation location: CGPoint, windowHeight: CGFloat) -> CGPoint {
        CGPoint(x: location.x, y: windowHeight - location.y)
    }

    private func drainMainQueue() {
        let expectation = XCTestExpectation(description: "Drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 1)
    }

    private func programColumnHost(resetID: AnyHashable, cardHeights: [CGFloat]) -> some View {
        ProgramColumnTicketScrollView(resetID: resetID) {
            ProgramLaneScrollFixture(cardHeights: cardHeights)
        }
        .frame(width: 270, height: 633)
    }

    private func programColumnsHost(
        backlogResetID: AnyHashable,
        doneResetID: AnyHashable,
        backlogCardHeights: [CGFloat],
        doneCardHeights: [CGFloat]
    ) -> some View {
        HStack(spacing: 20) {
            ProgramColumnTicketScrollView(resetID: backlogResetID) {
                ProgramLaneScrollFixture(cardHeights: backlogCardHeights)
            }
            ProgramColumnTicketScrollView(resetID: doneResetID) {
                ProgramLaneScrollFixture(cardHeights: doneCardHeights)
            }
        }
        .frame(width: 560, height: 633)
    }

    private func programWorkColumnHost(model: ProgramBoardViewModel, lane: ProgramBoardLane) -> some View {
        ProgramWorkColumnPanel(
            model: model,
            lane: lane,
            showsProjectContext: true,
            theme: nil,
            canCreate: true,
            onCreate: {},
            onDrop: { _, _, _ in }
        )
        .frame(width: 270, height: BoardSurfaceLayout.columnHeight)
        .coordinateSpace(name: "programBoard")
    }

    private func programDashboardSnapshot(
        backlogItems: [ProgramStatusItem] = [],
        readyItems: [ProgramStatusItem] = [],
        inProgressItems: [ProgramStatusItem] = [],
        doneItems: [ProgramStatusItem]
    ) -> ProgramDashboardSnapshot {
        ProgramDashboardSnapshot(
            summary: programStatusResponse(
                query: "summary",
                items: [
                    ProgramStatusItem(
                        project: ProgramStatusProject(name: "relay-runner", path: "/repo/relay-runner"),
                        ticketID: nil,
                        title: nil,
                        status: nil,
                        priority: nil,
                        doneTickets: doneItems.count
                    ),
                ]
            ),
            backlogWork: programStatusResponse(query: "backlog_lane", items: backlogItems),
            readyWork: programStatusResponse(query: "ready_lane", items: readyItems),
            inProgressWork: programStatusResponse(query: "in_progress_lane", items: inProgressItems),
            doneWork: programStatusResponse(query: "done_lane", items: doneItems),
            awaitingMerge: programStatusResponse(query: "awaiting_merge", items: [])
        )
    }

    private func programStatusResponse(query: String, items: [ProgramStatusItem]) -> ProgramStatusResponse {
        ProgramStatusResponse(
            query: query,
            provider: nil,
            message: "Response.",
            items: items,
            counts: ProgramStatusCounts(projects: 1, items: items.count)
        )
    }

    private func doneTickets(start: Int, count: Int) -> [ProgramStatusItem] {
        (start..<(start + count)).map { index in
            programWorkItem(
                ticketID: "RR-\(index)",
                title: "Done ticket \(index) with variable copy length \(String(repeating: "detail ", count: index % 4 + 1))",
                status: Ticket.Status.done.rawValue,
                dependsOn: index % 3 == 0 ? ["RR-\(index - 1)"] : []
            )
        }
    }

    private func laneTickets(prefix: String, status: String, count: Int) -> [ProgramStatusItem] {
        (0..<count).map { index in
            programWorkItem(
                ticketID: "\(prefix)-\(index)",
                title: "Workspace lane ticket \(index) with variable card copy \(String(repeating: "detail ", count: index % 5 + 1))",
                status: status,
                dependsOn: index % 4 == 0 ? ["\(prefix)-dependency-\(index)"] : []
            )
        }
    }

    private func programWorkItem(
        ticketID: String,
        title: String,
        status: String,
        dependsOn: [String] = []
    ) -> ProgramStatusItem {
        ProgramStatusItem(
            project: ProgramStatusProject(name: "relay-runner", path: "/repo/relay-runner"),
            ticketID: ticketID,
            title: title,
            status: status,
            priority: Ticket.Priority.medium.rawValue,
            dependsOn: dependsOn
        )
    }
}

private struct ProgramLaneScrollFixture: View {
    let cardHeights: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.55))
                .frame(height: ProgramBoardLayout.dropIndicatorHeight)
                .padding(.horizontal, 4)
                .padding(.bottom, ProgramBoardLayout.dropIndicatorBottomPadding)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(cardHeights.enumerated()), id: \.offset) { index, height in
                    VStack(alignment: .leading, spacing: 8) {
                        if index == 0 {
                            ProgramLaneFirstCardMarker()
                                .frame(height: 1)
                        }
                        Text("Ticket \(index)")
                            .font(AppTypography.font(.ticketTitle))
                            .lineLimit(2)
                        Text("Dependency and status detail for ticket \(index)")
                            .font(AppTypography.font(.supporting))
                            .lineLimit(2)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: BoardDarkSurfaceStyle.nestedCardCornerRadius)
                            .fill(BoardDarkSurfaceStyle.contentFill)
                    )
                }
            }
        }
    }
}

private final class ProgramLaneFirstCardMarkerView: NSView {}

private struct ProgramLaneFirstCardMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ProgramLaneFirstCardMarkerView {
        ProgramLaneFirstCardMarkerView()
    }

    func updateNSView(_ nsView: ProgramLaneFirstCardMarkerView, context: Context) {}
}
