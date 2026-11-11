import XCTest
@testable import relay_runner

final class RelayScrollEdgeFadeTests: XCTestCase {
    func testNoFadeWhenContentFitsTheViewport() {
        let fades = RelayScrollEdgeFade.lengths(offset: 0, contentLength: 300, viewportLength: 400)
        XCTAssertEqual(fades.leading, 0)
        XCTAssertEqual(fades.trailing, 0)
    }

    func testOnlyTheFarEdgeFadesAtRest() {
        let fades = RelayScrollEdgeFade.lengths(offset: 0, contentLength: 1000, viewportLength: 400)
        XCTAssertEqual(fades.leading, 0)
        XCTAssertEqual(fades.trailing, RelayScrollEdgeFade.length)
    }

    func testTheLeadingFadeGrowsWithTheOffsetUpToItsLength() {
        let partial = RelayScrollEdgeFade.lengths(offset: 10, contentLength: 1000, viewportLength: 400)
        XCTAssertEqual(partial.leading, 10)
        let full = RelayScrollEdgeFade.lengths(offset: 300, contentLength: 1000, viewportLength: 400)
        XCTAssertEqual(full.leading, RelayScrollEdgeFade.length)
        XCTAssertEqual(full.trailing, RelayScrollEdgeFade.length)
    }

    func testOnlyTheNearEdgeFadesAtTheEnd() {
        let fades = RelayScrollEdgeFade.lengths(offset: 600, contentLength: 1000, viewportLength: 400)
        XCTAssertEqual(fades.leading, RelayScrollEdgeFade.length)
        XCTAssertEqual(fades.trailing, 0)
        let overscroll = RelayScrollEdgeFade.lengths(offset: 650, contentLength: 1000, viewportLength: 400)
        XCTAssertEqual(overscroll.trailing, 0)
    }

    /// A `TextEditor` scrolls in AppKit: the observer finds the scroll view it
    /// fills and reports its extent as it scrolls, so its edges fade too.
    @MainActor
    func testAppKitObserverFollowsTheScrollViewItFills() {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = root
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        root.addSubview(scroll)
        let observer = RelayAppKitScrollObserverView(frame: root.bounds)
        var extent: RelayScrollExtent?
        observer.onChange = { extent = $0 }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        root.addSubview(observer)
        settle()
        XCTAssertEqual(extent, RelayScrollExtent(offset: 0, content: 400, viewport: 100))
        XCTAssertEqual(extent?.fades.leading, 0, "At rest the top stays solid")
        XCTAssertEqual(extent?.fades.trailing, RelayScrollEdgeFade.length)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
        settle()
        XCTAssertEqual(extent?.offset, 150)
        XCTAssertEqual(extent?.fades.leading, RelayScrollEdgeFade.length)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        settle()
        XCTAssertEqual(extent?.fades.trailing, 0, "At the end the bottom stays solid")
    }
}
