import Foundation
import XCTest
@testable import relay_runner

/// RR-550: the Workspace History chat keeps one in-memory conversation per
/// repository and per historical ticket, and follows the selected repository.
@MainActor
final class WorkspaceHistoryChatTests: XCTestCase {
    private func card(_ ticketID: String) -> ArtifactHistoryCard {
        ArtifactHistoryCard(
            artifactID: "ticket-\(ticketID)",
            ticketID: ticketID,
            title: "Ticket \(ticketID)",
            status: "done",
            activityAt: "2026-11-20T00:00:00Z",
            state: "archived",
            attachmentCount: 0,
            attachmentBytes: 0
        )
    }

    private func history(_ repoPath: String) -> WorkspaceHistoryViewModel {
        WorkspaceHistoryViewModel(repoPath: repoPath, projectName: "P", projectScopeToken: nil)
    }

    func testConversationsAreSeparatePerRepositoryAndTicketAndFollowTheRepository() async {
        var asked: [WorkspaceHistoryChatScope] = []
        let chat = WorkspaceHistoryChatModel { scope, messages in
            asked.append(scope)
            return "answer \(messages.count)"
        }

        // Repository A's history, then one of its tickets.
        let repoA = history("/repo/a")
        let historyA = repoA.chatScope
        XCTAssertEqual(historyA, WorkspaceHistoryChatScope(repoPath: "/repo/a", artifactID: nil))
        chat.setDraft("What shipped?", for: historyA)
        await chat.send(in: historyA)?.value
        repoA.selectedCard = card("RR-1")
        let ticketA = repoA.chatScope
        XCTAssertEqual(ticketA, WorkspaceHistoryChatScope(repoPath: "/repo/a", artifactID: "ticket-RR-1"))
        XCTAssertTrue(chat.conversation(for: ticketA).messages.isEmpty)
        chat.setDraft("Why this ticket?", for: ticketA)
        await chat.send(in: ticketA)?.value
        // Closing the ticket returns to the repository's conversation.
        repoA.close()
        XCTAssertEqual(chat.conversation(for: repoA.chatScope).messages.map(\.text), ["What shipped?", "answer 1"])

        // Switching History to repository B shows B's own conversation, even
        // for a ticket with the same artifact id.
        let repoB = history("/repo/b")
        XCTAssertTrue(chat.conversation(for: repoB.chatScope).messages.isEmpty)
        repoB.selectedCard = card("RR-1")
        XCTAssertTrue(chat.conversation(for: repoB.chatScope).messages.isEmpty)
        repoB.close()
        chat.setDraft("Anything blocked?", for: repoB.chatScope)
        await chat.send(in: repoB.chatScope)?.value

        // Switching back (History builds a fresh model per repository) picks
        // up A's conversations where they were.
        let backToA = history("/repo/a")
        XCTAssertEqual(chat.conversation(for: backToA.chatScope).messages.map(\.text), ["What shipped?", "answer 1"])
        backToA.selectedCard = card("RR-1")
        XCTAssertEqual(chat.conversation(for: backToA.chatScope).messages.map(\.text), ["Why this ticket?", "answer 1"])
        XCTAssertEqual(chat.conversation(for: repoB.chatScope).messages.map(\.text), ["Anything blocked?", "answer 1"])
        XCTAssertEqual(asked, [
            historyA,
            ticketA,
            WorkspaceHistoryChatScope(repoPath: "/repo/b", artifactID: nil),
        ])
    }

    func testChatRequestCarriesTheTicketAndNoOnlineFlags() throws {
        let messages = [
            NoteChatMessage(role: .user, text: "What changed?"),
            NoteChatMessage(role: .assistant, text: "The redirect."),
            NoteChatMessage(role: .user, text: "Who did it?"),
        ]
        let ticketRequest = try XCTUnwrap(OrchestratorClient.historyChatRequest(
            artifactID: "ticket-RR-1", messages: messages,
            repoPath: "/repo/a", projectScopeToken: "token-a", port: 7634
        ))
        XCTAssertEqual(ticketRequest.url?.path, "/v1/artifacts/history/chat")
        XCTAssertEqual(ticketRequest.httpMethod, "POST")
        let ticketBody = try jsonBody(ticketRequest)
        XCTAssertEqual(ticketBody["artifact_id"] as? String, "ticket-RR-1")
        XCTAssertEqual(ticketBody["repo_path"] as? String, "/repo/a")
        XCTAssertEqual(ticketBody["project_scope_token"] as? String, "token-a")
        XCTAssertFalse((ticketBody["request_id"] as? String ?? "").isEmpty)
        // The chat never asks for an online fetch or a GitHub exposure confirmation.
        XCTAssertNil(ticketBody["online"])
        XCTAssertNil(ticketBody["confirm_github_exposure"])
        let sent = try XCTUnwrap(ticketBody["messages"] as? [[String: String]])
        XCTAssertEqual(sent, [
            ["role": "user", "text": "What changed?"],
            ["role": "assistant", "text": "The redirect."],
            ["role": "user", "text": "Who did it?"],
        ])

        let historyRequest = try XCTUnwrap(OrchestratorClient.historyChatRequest(
            artifactID: nil, messages: [messages[0]],
            repoPath: "/repo/a", projectScopeToken: nil, port: 7634
        ))
        XCTAssertNil(try jsonBody(historyRequest)["artifact_id"])
        XCTAssertGreaterThan(historyRequest.timeoutInterval, 120)
    }

    func testHistoryChatResponseDecodes() throws {
        let data = Data(#"{"reply": "RR-2 fixed it.", "artifact_ids": ["ticket-RR-2"]}"#.utf8)
        let response = try JSONDecoder().decode(OrchestratorClient.HistoryChatResponse.self, from: data)
        XCTAssertEqual(response.reply, "RR-2 fixed it.")
        XCTAssertEqual(response.artifactIDs, ["ticket-RR-2"])
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
