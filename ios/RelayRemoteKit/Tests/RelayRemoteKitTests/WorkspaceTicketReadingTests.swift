import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// RR-551: the ticket modal's header and body states.
final class WorkspaceTicketReadingTests: XCTestCase {
    private let row = WorkspaceTicket(id: "RR-120", title: "Move the board", status: .inProgress, projectId: "p1",
                                      agent: "george")
    private func list(_ tickets: [WorkspaceTicket], truncated: Bool? = nil, error: String? = nil) -> WorkspaceState {
        WorkspaceState(projects: [WorkspaceProject(id: "p1", name: "relay-runner")], tickets: tickets, error: error,
                       truncated: truncated)
    }

    func testTheHeaderFillsFromTheRowAtOnceAndOnlyTheBodyWaits() {
        let reading = WorkspaceTicketReading(row: row, workspace: list([row]), reply: nil)
        XCTAssertEqual(reading.eyebrow, "RR-120 · relay-runner")
        XCTAssertEqual(reading.title, "Move the board")
        XCTAssertEqual(reading.statusLine, "In progress · George")
        XCTAssertEqual(reading.body, .loading)
    }

    func testStatusLineHasNoAgentWhenThereIsNone() {
        let queued = WorkspaceTicket(id: "RR-1", title: "T", status: .queued, projectId: "p1")
        XCTAssertEqual(WorkspaceTicketReading(row: queued, workspace: list([queued]), reply: nil).statusLine, "Queued")
        let backlog = WorkspaceTicket(id: "RR-2", title: "T", status: .backlog, projectId: "p1")
        XCTAssertEqual(WorkspaceTicketReading(row: backlog, workspace: list([backlog]), reply: nil).statusLine, "Backlog")
    }

    func testTheReplyGivesTheTextTruncationAndErrors() {
        let ok = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", title: "Longer title", status: .inProgress,
                                       markdown: "Body", truncated: true)
        let reading = WorkspaceTicketReading(row: row, workspace: list([row]), reply: ok)
        XCTAssertEqual(reading.body, .text("Body", truncated: true))
        XCTAssertEqual(reading.title, "Longer title")
        let plain = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", markdown: "Body")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: plain).body, .text("Body", truncated: false))
        let failed = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", error: "That ticket no longer exists.")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: failed).body,
                       .error("That ticket no longer exists."))
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: failed).title, "Move the board",
                       "an error reply has no title, so the row's stays")
    }

    func testAnOlderMacAndASilentMac() {
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: nil, unsupported: true).body, .unsupported)
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: nil, timedOut: true).body,
                       .error(WorkspaceTicketReading.silentMessage))
        let late = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", markdown: "Body")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: late, timedOut: true).body,
                       .text("Body", truncated: false), "an answer beats the timeout")
    }

    func testAPushedListUpdatesTheHeaderAndALeavingTicketIsDone() {
        var moved = row
        moved.status = .queued
        moved.agent = nil
        let pushed = WorkspaceTicketReading(row: row, workspace: list([moved]), reply: nil)
        XCTAssertEqual(pushed.statusLine, "Queued")
        let gone = WorkspaceTicketReading(row: row, workspace: list([]), reply: nil)
        XCTAssertEqual(gone.status, .done)
        XCTAssertEqual(gone.statusLine, "Done · George")
        let text = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", markdown: "Still here")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: list([]), reply: text).body,
                       .text("Still here", truncated: false), "the text stays")
    }

    func testAListThatSaysNothingDoesNotMakeATicketDone() {
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: list([], truncated: true), reply: nil).status, .inProgress)
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: list([], error: "down"), reply: nil).status, .inProgress)
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: nil).status, .inProgress)
        let done = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-120", status: .done, markdown: "x")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: nil, reply: done).status, .done)
    }

    func testAnotherProjectsTicketWithTheSameIDIsNotThisOne() {
        let other = WorkspaceTicket(id: "RR-120", title: "Other", status: .backlog, projectId: "p2")
        XCTAssertEqual(WorkspaceTicketReading(row: row, workspace: list([other]), reply: nil).status, .done)
    }
}
