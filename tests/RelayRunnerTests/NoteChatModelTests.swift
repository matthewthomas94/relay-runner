import Foundation
import XCTest
@testable import relay_runner

/// RR-549: the Notes chat keeps one in-memory conversation per scope.
@MainActor
final class NoteChatModelTests: XCTestCase {
    private let noteA = NoteChatScope.note(noteID: "N-1", projectPath: "/notes")
    private let noteB = NoteChatScope.note(noteID: "N-2", projectPath: "/notes")

    func testEachNoteAndTheLibraryKeepSeparateConversations() async {
        var asked: [(NoteChatScope, [NoteChatMessage])] = []
        let chat = NoteChatModel { scope, messages in
            asked.append((scope, messages))
            return "answer \(messages.count)"
        }

        chat.setDraft("About A?", for: noteA)
        await chat.send(in: noteA)?.value
        chat.setDraft("About everything?", for: .library)
        await chat.send(in: .library)?.value
        chat.setDraft("About B?", for: noteB)
        await chat.send(in: noteB)?.value
        // Coming back to A carries on A's conversation only.
        chat.setDraft("More on A?", for: noteA)
        await chat.send(in: noteA)?.value

        XCTAssertEqual(
            chat.conversation(for: noteA).messages.map(\.text),
            ["About A?", "answer 1", "More on A?", "answer 3"]
        )
        XCTAssertEqual(chat.conversation(for: noteB).messages.map(\.text), ["About B?", "answer 1"])
        XCTAssertEqual(chat.conversation(for: .library).messages.map(\.text), ["About everything?", "answer 1"])
        XCTAssertEqual(asked.map(\.0), [noteA, .library, noteB, noteA])
        XCTAssertEqual(asked.last?.1.map(\.role), [.user, .assistant, .user])
    }

    func testReturnSendsAndShiftReturnInsertsNewline() async {
        XCTAssertEqual(NoteChatReturnKeyAction.action(shift: false), .send)
        XCTAssertEqual(NoteChatReturnKeyAction.action(shift: true), .insertNewline)

        var questions: [String] = []
        let chat = NoteChatModel { _, messages in
            questions.append(messages.last?.text ?? "")
            return "ok"
        }
        chat.setDraft("first line", for: .library)
        XCTAssertNil(chat.handleReturn(shift: true, in: .library))
        XCTAssertEqual(chat.conversation(for: .library).draft, "first line\n")
        XCTAssertTrue(chat.conversation(for: .library).messages.isEmpty)

        chat.setDraft("first line\nsecond line", for: .library)
        await chat.handleReturn(shift: false, in: .library)?.value
        XCTAssertEqual(questions, ["first line\nsecond line"])
        XCTAssertEqual(chat.conversation(for: .library).draft, "")
    }

    func testBlankDraftDoesNotSend() {
        let chat = NoteChatModel { _, _ in
            XCTFail("a blank draft must not be sent")
            return ""
        }
        chat.setDraft("  \n ", for: .library)
        XCTAssertFalse(chat.conversation(for: .library).canSend)
        XCTAssertNil(chat.send(in: .library))
    }

    func testSendingIsDisabledWhileAReplyIsPending() async {
        let gate = AsyncGate()
        var calls = 0
        let chat = NoteChatModel { _, _ in
            calls += 1
            await gate.wait()
            return "done"
        }
        chat.setDraft("Question?", for: noteA)
        let task = chat.send(in: noteA)
        // The question shows at once with a pending reply.
        XCTAssertEqual(chat.conversation(for: noteA).messages.map(\.text), ["Question?"])
        XCTAssertTrue(chat.conversation(for: noteA).isPending)

        chat.setDraft("Another?", for: noteA)
        XCTAssertFalse(chat.conversation(for: noteA).canSend)
        XCTAssertNil(chat.send(in: noteA))
        XCTAssertNil(chat.handleReturn(shift: false, in: noteA))
        // Another scope is not blocked by this one's pending reply.
        chat.setDraft("Library?", for: .library)
        XCTAssertTrue(chat.conversation(for: .library).canSend)

        await gate.open()
        await task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(chat.conversation(for: noteA).isPending)
        XCTAssertEqual(chat.conversation(for: noteA).messages.map(\.text), ["Question?", "done"])
        XCTAssertEqual(chat.conversation(for: noteA).draft, "Another?")
        XCTAssertTrue(chat.conversation(for: noteA).canSend)
    }

    func testErrorKeepsTheQuestionAndRetryAsksAgain() async {
        var failures = 1
        var asked: [[String]] = []
        let chat = NoteChatModel { _, messages in
            asked.append(messages.map(\.text))
            if failures > 0 {
                failures -= 1
                throw OrchestratorClientError.badStatus(
                    504, #"{"error":"The provider did not answer in time.","error_code":"timeout","retryable":true}"#
                )
            }
            return "Here it is."
        }
        chat.setDraft("What was decided?", for: noteA)
        await chat.send(in: noteA)?.value

        var conversation = chat.conversation(for: noteA)
        XCTAssertEqual(conversation.messages.map(\.text), ["What was decided?"])
        XCTAssertEqual(conversation.errorMessage, "The provider did not answer in time.")
        XCTAssertFalse(conversation.isPending)
        XCTAssertTrue(conversation.canRetry)

        await chat.retry(in: noteA)?.value
        conversation = chat.conversation(for: noteA)
        XCTAssertNil(conversation.errorMessage)
        XCTAssertFalse(conversation.canRetry)
        XCTAssertEqual(conversation.messages.map(\.text), ["What was decided?", "Here it is."])
        XCTAssertEqual(asked, [["What was decided?"], ["What was decided?"]])
        XCTAssertNil(chat.retry(in: noteA))
    }

    func testErrorWithoutDaemonMessageFallsBackToPlainText() {
        XCTAssertEqual(
            NoteChatModel.errorMessage(for: URLError(.timedOut)),
            "No answer arrived in time."
        )
        XCTAssertEqual(
            NoteChatModel.errorMessage(for: OrchestratorClientError.badStatus(502, "")),
            "Couldn't get an answer. Check that Relay Runner is running, then retry."
        )
    }

    func testChatRequestSendsTheNoteIDOnlyForANote() throws {
        let messages = [
            NoteChatMessage(role: .user, text: "Hi"),
            NoteChatMessage(role: .assistant, text: "Hello"),
            NoteChatMessage(role: .user, text: "Summary?"),
        ]
        let noteRequest = try XCTUnwrap(OrchestratorClient.noteChatRequest(
            note: "N-1", messages: messages,
            repoPath: GlobalNoteStore.repositoryPath, projectScopeToken: nil, port: 7634
        ))
        XCTAssertEqual(noteRequest.url?.path, "/v1/artifacts/notes/chat")
        XCTAssertEqual(noteRequest.httpMethod, "POST")
        let noteBody = try jsonBody(noteRequest)
        XCTAssertEqual(noteBody["note"] as? String, "N-1")
        XCTAssertEqual(noteBody["repo_path"] as? String, "")
        XCTAssertFalse((noteBody["request_id"] as? String ?? "").isEmpty)
        let sent = try XCTUnwrap(noteBody["messages"] as? [[String: String]])
        XCTAssertEqual(sent, [
            ["role": "user", "text": "Hi"],
            ["role": "assistant", "text": "Hello"],
            ["role": "user", "text": "Summary?"],
        ])

        let libraryRequest = try XCTUnwrap(OrchestratorClient.noteChatRequest(
            note: nil, messages: [messages[0]],
            repoPath: GlobalNoteStore.repositoryPath, projectScopeToken: nil, port: 7634
        ))
        XCTAssertNil(try jsonBody(libraryRequest)["note"])
        XCTAssertGreaterThan(libraryRequest.timeoutInterval, 120)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Holds an answer until the test opens it.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
