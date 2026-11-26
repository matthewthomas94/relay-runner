import Foundation
import Observation

/// RR-549: what a Notes chat asks about — one note, or the whole library.
enum NoteChatScope: Hashable {
    case library
    case note(noteID: String, projectPath: String)
}

struct NoteChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct NoteChatConversation: Equatable {
    var messages: [NoteChatMessage] = []
    var draft = ""
    var isPending = false
    /// Why the last question got no answer; the question stays in `messages`.
    var errorMessage: String?

    var canSend: Bool {
        !isPending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRetry: Bool {
        !isPending && errorMessage != nil && messages.last?.role == .user
    }
}

/// Return sends; Shift-Return adds a new line.
enum NoteChatReturnKeyAction: Equatable {
    case send
    case insertNewline

    static func action(shift: Bool) -> Self {
        shift ? .insertNewline : .send
    }
}

/// RR-549: one in-memory conversation per scope for the life of the app.
/// Nothing here is written to a note. Conversations change on the main actor.
/// RR-550's Workspace History chat is the same model over its own scope.
@Observable
final class ChatThreadModel<Scope: Hashable> {
    typealias Answer = (Scope, [NoteChatMessage]) async throws -> String

    private(set) var conversations: [Scope: NoteChatConversation] = [:]
    @ObservationIgnored private var answer: Answer

    init(answer: @escaping Answer = { _, _ in throw OrchestratorClientError.invalidRequest }) {
        self.answer = answer
    }

    func setAnswer(_ answer: @escaping Answer) {
        self.answer = answer
    }

    @MainActor
    func conversation(for scope: Scope) -> NoteChatConversation {
        conversations[scope] ?? NoteChatConversation()
    }

    @MainActor
    func setDraft(_ draft: String, for scope: Scope) {
        conversations[scope, default: NoteChatConversation()].draft = draft
    }

    /// Applies Return or Shift-Return in the composer.
    @MainActor @discardableResult
    func handleReturn(shift: Bool, in scope: Scope) -> Task<Void, Never>? {
        switch NoteChatReturnKeyAction.action(shift: shift) {
        case .insertNewline:
            conversations[scope, default: NoteChatConversation()].draft += "\n"
            return nil
        case .send:
            return send(in: scope)
        }
    }

    /// Sends the scope's draft. The question appears at once; the reply is
    /// appended when it arrives. Ignored while a reply is pending.
    @MainActor @discardableResult
    func send(in scope: Scope) -> Task<Void, Never>? {
        var conversation = conversation(for: scope)
        guard conversation.canSend else { return nil }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.messages.append(NoteChatMessage(role: .user, text: text))
        conversation.draft = ""
        conversations[scope] = conversation
        return request(in: scope)
    }

    /// Asks the failed question again.
    @MainActor @discardableResult
    func retry(in scope: Scope) -> Task<Void, Never>? {
        guard conversation(for: scope).canRetry else { return nil }
        return request(in: scope)
    }

    @MainActor
    private func request(in scope: Scope) -> Task<Void, Never> {
        conversations[scope, default: NoteChatConversation()].isPending = true
        conversations[scope]?.errorMessage = nil
        let messages = conversation(for: scope).messages
        let answer = self.answer
        return Task { @MainActor [weak self] in
            do {
                let reply = try await answer(scope, messages)
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.finish(scope, reply: text.isEmpty ? "No answer came back." : text)
            } catch {
                self?.fail(scope, message: Self.errorMessage(for: error))
            }
        }
    }

    @MainActor
    private func finish(_ scope: Scope, reply: String) {
        conversations[scope]?.messages.append(NoteChatMessage(role: .assistant, text: reply))
        conversations[scope]?.isPending = false
    }

    @MainActor
    private func fail(_ scope: Scope, message: String) {
        conversations[scope]?.isPending = false
        conversations[scope]?.errorMessage = message
    }

    static func errorMessage(for error: Error) -> String {
        if let error = error as? OrchestratorClientError, let message = error.daemonErrorMessage {
            return message
        }
        if (error as? URLError)?.code == .timedOut {
            return "No answer arrived in time."
        }
        return "Couldn't get an answer. Check that Relay Runner is running, then retry."
    }
}

typealias NoteChatModel = ChatThreadModel<NoteChatScope>
