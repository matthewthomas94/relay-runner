import AppKit
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

    private func scrollViews(in container: BoardOverlayScrollContainer) throws -> (
        scrollView: NSScrollView,
        documentView: NSView,
        hostingView: NSView
    ) {
        let scrollView = try XCTUnwrap(container.subviews.compactMap { $0 as? NSScrollView }.first)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let hostingView = try XCTUnwrap(documentView.subviews.first)
        return (scrollView, documentView, hostingView)
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

    private func textValues(in view: NSView) -> [String] {
        let currentValue = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return currentValue + view.subviews.flatMap(textValues(in:))
    }
}
