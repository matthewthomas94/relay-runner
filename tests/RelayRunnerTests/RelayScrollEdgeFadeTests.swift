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
}
