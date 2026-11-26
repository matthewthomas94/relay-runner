import RelayRemoteKit
import RelayRemoteProtocol
import XCTest
@testable import RelayRemote

/// RR-551: the Workspace tab's ticket modal.
final class TicketModalTests: XCTestCase {
    private let row = WorkspaceTicket(id: "RR-532", title: "Tab bar", status: .inProgress, projectId: "p1", agent: "george")

    @MainActor
    func testOpeningARowShowsItAndEachAskCountsOnce() {
        let model = AppModel()
        XCTAssertFalse(model.isTicketOpen)
        XCTAssertEqual(model.ticketRequests, 0)
        model.openTicket(row)
        XCTAssertTrue(model.isTicketOpen)
        XCTAssertEqual(model.shownTicket, row)
        XCTAssertEqual(model.ticketRequests, 1)
        model.refreshTicket()
        XCTAssertEqual(model.ticketRequests, 2)
        model.closeTicket()
        XCTAssertFalse(model.isTicketOpen)
        XCTAssertEqual(model.shownTicket, row, "the text stays while the modal fades out")
        model.refreshTicket()
        XCTAssertEqual(model.ticketRequests, 2, "a closed modal asks for nothing")
    }

    @MainActor
    func testTheProjectTabIsUntouchedByTheModal() {
        let model = AppModel()
        model.workspaceProject = "p1"
        model.openTicket(row)
        model.closeTicket()
        XCTAssertEqual(model.workspaceProject, "p1")
    }

    func testOnlyWebAndMailLinksLeaveTheApp() {
        for allowed in ["https://example.com/x", "http://example.com", "mailto:a@b.c", "HTTPS://EXAMPLE.COM"] {
            XCTAssertTrue(MarkdownView.opensInTheBrowser(URL(string: allowed)!), allowed)
        }
        for refused in ["file:///etc/passwd", "relay://x", "javascript:alert(1)", "tel:123"] {
            XCTAssertFalse(MarkdownView.opensInTheBrowser(URL(string: refused)!), refused)
        }
    }

    func testHeadingStylesStepDownFromTheTitle() {
        XCTAssertEqual(MarkdownView.headingStyle(1), .titleL)
        XCTAssertEqual(MarkdownView.headingStyle(2), .cardTitle)
        XCTAssertEqual(MarkdownView.headingStyle(3), .section)
        XCTAssertEqual(MarkdownView.headingStyle(6), .section)
    }

    func testTheSampleLaunchOption() {
        XCTAssertEqual(LaunchOptions(arguments: ["--ticket-sample=long"]).ticketSample, "long")
        XCTAssertNil(LaunchOptions(arguments: []).ticketSample)
    }

    func testEachSampleReadsAsItsState() throws {
        func body(_ name: String) throws -> WorkspaceTicketReading.Body {
            let sample = try XCTUnwrap(TicketSample.debugSample(name))
            return WorkspaceTicketReading(row: sample.row, workspace: sample.workspace, reply: sample.reply,
                                          unsupported: sample.unsupported).body
        }
        XCTAssertEqual(try body("loading"), .loading)
        XCTAssertEqual(try body("unsupported"), .unsupported)
        guard case .error = try body("error") else { return XCTFail("expected an error") }
        guard case .text(_, let cut) = try body("truncated") else { return XCTFail("expected text") }
        XCTAssertTrue(cut)
        guard case .text(let markdown, let notCut) = try body("short") else { return XCTFail("expected text") }
        XCTAssertFalse(notCut)
        // The sample holds each element the modal draws.
        let blocks = MarkdownBlocks.parse(markdown)
        XCTAssertEqual(blocks.compactMap { if case .heading(let level, _) = $0 { level } else { nil } }, [2, 3])
        XCTAssertTrue(blocks.contains { if case .code = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .list(let items) = $0 { items.contains { $0.marker == .task(checked: true) } } else { false } })
        let done = try XCTUnwrap(TicketSample.debugSample("done"))
        XCTAssertEqual(WorkspaceTicketReading(row: done.row, workspace: done.workspace, reply: done.reply).status, .done)
        XCTAssertTrue(try XCTUnwrap(TicketSample.debugSample("short", unreachable: true)).isUnreachable)
    }
}
