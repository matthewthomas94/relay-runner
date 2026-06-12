import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

@MainActor
final class BoardOverlayScrollViewTests: XCTestCase {
    func testShortContentStaysTopAlignedWhileDocumentFillsViewport() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 40)))

        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertEqual(views.documentView.frame.height, views.scrollView.contentView.bounds.height, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.height, 40, accuracy: 0.5)
    }

    func testTallContentExpandsDocumentForScrolling() throws {
        let container = BoardOverlayScrollContainer(rootView: AnyView(Rectangle().frame(height: 520)))

        layout(container, width: 200, height: 300)

        let views = try scrollViews(in: container)
        XCTAssertGreaterThan(views.documentView.frame.height, views.scrollView.contentView.bounds.height)
        XCTAssertEqual(views.hostingView.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(views.hostingView.frame.height, views.documentView.frame.height, accuracy: 0.5)
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
}
