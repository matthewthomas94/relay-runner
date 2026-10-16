import CryptoKit
import Darwin
import Foundation

/// A conversation is independent of its provider processes and repository cwd.
struct AssistantSessionContext: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case general, project }
    let kind: Kind
    let projectID: String?
    let repositoryPath: String?

    static let general = AssistantSessionContext(kind: .general, projectID: nil, repositoryPath: nil)
    var id: String { isGeneral ? "general" : "project:\(projectID ?? repositoryPath ?? "")" }
    var isGeneral: Bool { kind == .general }
    var displayName: String {
        isGeneral ? "General" : URL(fileURLWithPath: repositoryPath ?? "").lastPathComponent
    }
    var workingDirectory: String { repositoryPath ?? AssistantSessionStore.filesDirectory.path }

    static func project(_ token: ConfirmedProjectScopeToken) -> Self {
        Self(kind: .project, projectID: token.projectID, repositoryPath: token.repositoryPath)
    }
}

struct AssistantConversationEntry: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant, context }
    let id: String
    let contextID: String
    let role: Role
    let text: String
    let createdAt: Date
}

/// Operational session state stays outside the user files archive. The native
/// provider owns execution/recovery; this store never replays a saved request.
final class AssistantSessionStore {
    enum Lifecycle: String, Codable { case saved, starting, running, interrupted }
    struct Binding: Codable, Equatable {
        var context: AssistantSessionContext
        var provider: String
        var model: String
        var transportSessionID: String?
        var nativeSessionID: String?
        var transcriptPath: String?
        var transcriptOffset: UInt64? = nil
        var managedProcess: AssistantManagedProviderProcess? = nil
        var lifecycle: Lifecycle
        var lastActivity: Date
        var activeRunIDs: [Int]
        var pendingIntentIDs: [String]
        // A zero-turn Codex thread has a real writer UUID but no saved native
        // transcript yet. It can receive its first request, not resume later.
        var resumableNativeSessionID: String? {
            transcriptPath?.isEmpty == false ? nativeSessionID : nil
        }
    }
    struct Continuation: Codable, Equatable, Identifiable {
        enum State: String, Codable { case queued, submitting, consumed, recoveryRequired, cancelled }
        let id: String
        let source: [String: String]
        let destination: AssistantSessionContext
        let text: String
        var state: State = .queued
        var destinationOwner: [String: String]? = nil
        var submittedAt: Date? = nil
        var message: String? = nil
        var prompt: String { text }
    }
    struct Document: Codable, Equatable {
        var schemaVersion = 1
        var conversationID = UUID().uuidString.lowercased()
        var activeContext = AssistantSessionContext.general
        var bindings: [String: Binding] = [:]
        var history: [AssistantConversationEntry] = []
        var continuations: [String: Continuation]? = nil
    }
    struct NativeBinding: Decodable {
        let context_id: String
        let provider: String
        let provider_session_id: String
        let native_session_id: String?
        let working_directory: String
        let transcript_path: String?
        let provider_pid: Int?
        let provider_process_identity: String?
    }

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-runner")
    }
    static var filesDirectory: URL { rootDirectory.appendingPathComponent("files", isDirectory: true) }
    static let idleTimeout: TimeInterval = 30 * 60
    let directory: URL
    private(set) var document = Document()
    private(set) var loadError: String?

    init(directory: URL = AssistantSessionStore.rootDirectory.appendingPathComponent("sessions")) {
        self.directory = directory
        let url = directory.appendingPathComponent("conversation-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                document.history = document.history.map(Self.sanitizedEntry)
                for key in document.continuations?.keys.map({ $0 }) ?? [] {
                    if document.continuations?[key]?.state == .queued || document.continuations?[key]?.state == .submitting {
                        document.continuations?[key]?.state = .recoveryRequired
                        document.continuations?[key]?.message = "Continuation needs review after restart. Clear it and issue a new request; saved work is never replayed automatically."
                    }
                }
                for key in document.bindings.keys {
                    if document.bindings[key]?.lifecycle == .running || document.bindings[key]?.lifecycle == .starting {
                        document.bindings[key]?.lifecycle = .interrupted
                    }
                }
            } catch { loadError = "Saved conversation could not be read: \(error.localizedDescription)" }
        }
    }

    var activeContext: AssistantSessionContext { document.activeContext }
    var conversationID: String { document.conversationID }
    var managedProviderProcesses: [AssistantManagedProviderProcess] {
        document.bindings.values.compactMap(\.managedProcess)
    }
    func binding(for context: AssistantSessionContext) -> Binding? { document.bindings[context.id] }
    func history(for context: AssistantSessionContext) -> [AssistantConversationEntry] {
        document.history.filter { $0.contextID == context.id }
    }
    private static func continuationDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var pendingContinuation: Continuation? {
        document.continuations?.values.first { [.queued, .submitting, .recoveryRequired].contains($0.state) }
    }

    /// Only explicit activation tool input enters this outbox, never history.
    @discardableResult
    func reserveContinuation(source: [String: String], destination: AssistantSessionContext, text: String) throws -> Continuation {
        guard let turn = source["canonical_turn_id"], !turn.isEmpty,
              source["source_context_id"] == activeContext.id,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 9 }) else {
            throw NSError(domain: "RelayContinuation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Continuation needs an exact current request and bounded public text without terminal controls."])
        }
        let id = "continuation-" + Self.continuationDigest(turn + "|" + destination.id + "|" + destination.workingDirectory)
        if let existing = document.continuations?[id] {
            guard existing.text == text, existing.source == source else {
                throw NSError(domain: "RelayContinuation", code: 2, userInfo: [NSLocalizedDescriptionKey: "This source request already has a different continuation."])
            }
            return existing
        }
        guard pendingContinuation == nil else {
            throw NSError(domain: "RelayContinuation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Clear the pending continuation before forwarding another request."])
        }
        let continuation = Continuation(id: id, source: source, destination: destination, text: text)
        try update { document in
            if document.continuations == nil { document.continuations = [:] }
            document.continuations?[id] = continuation
        }
        return continuation
    }

    func updateContinuation(_ id: String, state: Continuation.State, owner: [String: String]? = nil,
                            message: String? = nil, now: Date = Date()) throws {
        guard let current = document.continuations?[id] else { return }
        // A duplicate timer/tool call can never return an uncertain or consumed
        // submission to the sendable state.
        guard current.state == .queued || (current.state == .submitting && state != .queued)
                || state == .cancelled else { return }
        try update { document in
            document.continuations?[id]?.state = state
            document.continuations?[id]?.message = message
            if let owner { document.continuations?[id]?.destinationOwner = owner }
            if state == .submitting { document.continuations?[id]?.submittedAt = now }
        }
    }

    /// Production delivery gate. Callers receive a prompt only after this
    /// durable transition succeeds; repeated polls can never return it twice.
    func prepareContinuationDelivery(sourceStatus: String?, context: AssistantSessionContext,
                                     ready: Bool, clearToSend: Bool, owner: [String: String],
                                     now: Date = Date()) throws -> Continuation? {
        guard let pending = pendingContinuation, pending.state == .queued,
              sourceStatus == "ready", context == pending.destination, ready, clearToSend,
              let binding = binding(for: context), binding.context == pending.destination,
              binding.transportSessionID == owner["provider_session_id"],
              binding.nativeSessionID == owner["native_session_id"],
              ["provider", "provider_session_id", "native_session_id", "app_session_id", "recovery_generation", "foreground_gate_handle"].allSatisfy({ owner[$0]?.isEmpty == false }) else { return nil }
        try updateContinuation(pending.id, state: .submitting, owner: owner, now: now)
        return pending
    }

    func cancelContinuation(unless destination: AssistantSessionContext? = nil) throws {
        guard let pending = pendingContinuation, destination != pending.destination else { return }
        try updateContinuation(pending.id, state: .cancelled)
    }

    func bindingURL(transportSessionID: String) -> URL {
        directory.appendingPathComponent("bindings/\(transportSessionID).json")
    }

    /// Persist before publishing a selection. Failure leaves the old context
    /// authoritative and never authorizes a replacement process.
    func select(_ context: AssistantSessionContext, provider: String, model: String,
                savingPreviousContext: Bool = false, now: Date = Date()) throws {
        try update { document in
            let previous = document.activeContext
            document.activeContext = context
            if document.bindings[context.id] == nil {
                document.bindings[context.id] = Binding(
                    context: context, provider: provider, model: model,
                    lifecycle: .saved, lastActivity: now, activeRunIDs: [], pendingIntentIDs: []
                )
            } else {
                document.bindings[context.id]?.context = context
            }
            if savingPreviousContext, context != previous {
                document.history.append(AssistantConversationEntry(
                    id: UUID().uuidString.lowercased(), contextID: context.id, role: .context,
                    text: "Switched to \(context.displayName)", createdAt: now
                ))
                // RR-394: a previous context whose session still runs keeps
                // its lifecycle; only a stopped one is recorded as saved.
                if let lifecycle = document.bindings[previous.id]?.lifecycle,
                   lifecycle != .running, lifecycle != .starting {
                    document.bindings[previous.id]?.lifecycle = .saved
                }
                document.bindings[previous.id]?.lastActivity = now
            }
        }
    }

    func begin(context: AssistantSessionContext, provider: String, model: String,
               transportSessionID: String, now: Date = Date()) throws {
        try update { document in
            var binding = document.bindings[context.id] ?? Binding(
                context: context, provider: provider, model: model,
                lifecycle: .saved, lastActivity: now, activeRunIDs: [], pendingIntentIDs: []
            )
            if binding.provider != provider || binding.model != model
                || (binding.transportSessionID != transportSessionID && binding.resumableNativeSessionID == nil) {
                binding.nativeSessionID = nil
                binding.transcriptPath = nil
                binding.transcriptOffset = nil
            }
            binding.provider = provider
            binding.model = model
            binding.context = context
            binding.managedProcess = nil
            binding.transportSessionID = transportSessionID
            binding.lifecycle = .starting
            binding.lastActivity = now
            document.bindings[context.id] = binding
            document.activeContext = context
        }
    }

    @discardableResult
    func saveIfIdle(context: AssistantSessionContext, now: Date, eligible: Bool, end: () -> Void) throws -> Bool {
        guard eligible, let binding = binding(for: context), now.timeIntervalSince(binding.lastActivity) >= Self.idleTimeout else { return false }
        try mark(.saved, context: context, now: now)
        end()
        return true
    }

    func mark(_ lifecycle: Lifecycle, context: AssistantSessionContext, now: Date = Date()) throws {
        try update { document in
            document.bindings[context.id]?.lifecycle = lifecycle
            document.bindings[context.id]?.lastActivity = now
        }
    }

    func append(_ entry: AssistantConversationEntry) throws {
        let entry = Self.sanitizedEntry(entry)
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !document.history.contains(where: { $0.id == entry.id }) else { return }
        try update { document in
            document.history.append(entry)
            document.bindings[entry.contextID]?.lastActivity = entry.createdAt
        }
    }

    func reconcile(context: AssistantSessionContext, activeRunIDs: [Int], pendingIntentIDs: [String]) throws {
        guard var binding = binding(for: context) else { return }
        binding.activeRunIDs = activeRunIDs
        binding.pendingIntentIDs = pendingIntentIDs
        if let transport = binding.transportSessionID,
           let data = try? Data(contentsOf: bindingURL(transportSessionID: transport)),
           let native = try? JSONDecoder().decode(NativeBinding.self, from: data),
           native.context_id == context.id, native.provider == binding.provider,
           native.provider_session_id == transport,
           Self.samePath(native.working_directory, context.workingDirectory) {
            if let pid = native.provider_pid, let identity = native.provider_process_identity, pid > 1, !identity.isEmpty {
                binding.managedProcess = AssistantManagedProviderProcess(pid: pid, identity: identity)
            }
            if let nativeID = native.native_session_id, UUID(uuidString: nativeID) != nil {
                // Startup may confirm a resumed UUID before its transcript is
                // reported again. Keep the validated path only for that UUID.
                let transcriptPath = native.transcript_path
                    ?? (binding.nativeSessionID == nativeID ? binding.transcriptPath : nil)
                if binding.nativeSessionID != nativeID || binding.transcriptPath != transcriptPath {
                    binding.transcriptOffset = nil
                }
                binding.nativeSessionID = nativeID
                binding.transcriptPath = transcriptPath
            }
        }
        guard document.bindings[context.id] != binding else { return }
        try update { $0.bindings[context.id] = binding }
    }

    /// A short public handoff only from the destination context. Native resume
    /// supplies its own full history; unrelated projects are never injected.
    func publicHandoff(for context: AssistantSessionContext) -> String {
        let text = history(for: context).suffix(6).map(Self.sanitizedEntry)
            .map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
        return String(text.suffix(4000))
    }

    /// Import only public message records from the exact provider transcript
    /// bound by its lifecycle hook. Tool output and reasoning are excluded.
    func importPublicHistory(context: AssistantSessionContext,
                             providerHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let binding = binding(for: context), let nativeID = binding.nativeSessionID,
              let path = binding.transcriptPath,
              UUID(uuidString: nativeID) != nil else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let nativeRoot = providerHome.appendingPathComponent(binding.provider == "codex" ? ".codex/sessions" : ".claude/projects")
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(nativeRoot), url.lastPathComponent.contains(nativeID),
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        // Read forward from a durable byte cursor. Large tool records between
        // polls cannot push a user's message out of a trailing-byte window.
        var offset = min(binding.transcriptOffset ?? 0, length)
        try handle.seek(toOffset: offset)
        var buffer = Data()
        var entries: [AssistantConversationEntry] = []
        var discardingOversizedRecord = false
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let end = buffer.index(after: newline)
                let line = buffer[..<end]
                if !discardingOversizedRecord {
                    entries += Self.publicEntries(data: Data(line), contextID: context.id,
                                                  nativeID: nativeID, provider: binding.provider)
                }
                offset += UInt64(line.count)
                buffer.removeSubrange(..<end)
                discardingOversizedRecord = false
            }
            // Provider tool results can be arbitrarily large. They are not
            // conversation entries; keep memory bounded while skipping them.
            if buffer.count > 4 * 1024 * 1024 {
                offset += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: false)
                discardingOversizedRecord = true
            }
        }
        // Leave an incomplete final JSON line for the next poll. If it is an
        // oversized record, do not commit its partial skip until a newline.
        if discardingOversizedRecord { offset = binding.transcriptOffset ?? 0 }
        let known = Set(document.history.map(\.id))
        let additions = entries.filter { !known.contains($0.id) }
        guard !additions.isEmpty || binding.transcriptOffset != offset else { return }
        try update { document in
            document.history.append(contentsOf: additions)
            document.bindings[context.id]?.transcriptOffset = offset
            if let latest = additions.map(\.createdAt).max(), latest > binding.lastActivity {
                document.bindings[context.id]?.lastActivity = min(latest, Date())
            }
        }
    }

    static func publicEntries(data: Data, contextID: String, nativeID: String, provider: String,
                              discardsFirstLine: Bool = false) -> [AssistantConversationEntry] {
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if discardsFirstLine, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { line in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            let message: [String: Any]
            if provider == "codex" {
                guard record["type"] as? String == "response_item",
                      let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      payload["channel"] as? String != "analysis",
                      payload["channel"] as? String != "summary" else { return nil }
                message = payload
            } else {
                guard ["user", "assistant"].contains(record["type"] as? String ?? ""),
                      record["isSidechain"] as? Bool != true,
                      let payload = record["message"] as? [String: Any] else { return nil }
                message = payload
            }
            guard let role = AssistantConversationEntry.Role(rawValue: message["role"] as? String ?? ""),
                  role != .context else { return nil }
            let text: String
            if let content = message["content"] as? String { text = content }
            else if let content = message["content"] as? [[String: Any]] {
                text = content.filter { ["text", "input_text", "output_text"].contains($0["type"] as? String ?? "") }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { return nil }
            let trimmed = (role == .user ? publicUserText(text) : text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !["<environment_context>", "<INSTRUCTIONS>", "<skills_instructions>", "# AGENTS.md instructions"].contains(where: trimmed.hasPrefix) else { return nil }
            let timestamp = (record["timestamp"] as? String).flatMap { value -> Date? in
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            } ?? Date(timeIntervalSince1970: 0)
            let digest = SHA256.hash(data: Data("\(nativeID):\(line)".utf8)).map { String(format: "%02x", $0) }.joined()
            return AssistantConversationEntry(id: digest, contextID: contextID, role: role,
                                              text: trimmed, createdAt: timestamp)
        }
    }

    /// Relay appends routing instructions to the original user text. Keep the
    /// turn, but exclude those known generated suffixes from visible history
    /// and any handoff, including entries saved by an older app version.
    static func publicUserText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = try? NSRegularExpression(pattern: #"\A<pasted_content id="([A-Za-z0-9_-]+)">\r?\n([\s\S]*)\r?\n</pasted_content id="\1">\z"#),
           let match = envelope.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let bodyRange = Range(match.range(at: 2), in: trimmed) {
            let body = String(trimmed[bodyRange])
            let publicText = publicUserText(body)
            // Native paste tags are hidden only when Relay's known routing
            // text proves this is an injected envelope, not a user's example.
            if publicText != body { return publicText }
        }
        if text.hasPrefix("Relay Runner command action:\n- action: "),
           let contract = text.range(of: "\n\nPM frontstage contract:\n- You are the PM frontstage for the user, not the implementation worker."),
           let source = text.range(of: "\n\nSource command:\n", range: contract.upperBound..<text.endIndex) {
            let header = text[..<contract.lowerBound]
            if header.contains("\n- ticket_id: "), header.contains("\n- outcome_to_report: "),
               header.contains("\n- relay_command_seq: "), header.contains("\n- relay_command_id: ") {
                let original = String(text[source.upperBound...])
                if !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return publicUserText(original) }
            }
        }
        let prefixes = [
            "\n\nRelay Runner command action:\n- action: ",
            "\n\nRelay Runner General work contract:\n- action: ",
            "\n\nRelay work-intent disposition:\n- route: ",
            "\n\nRelay intent qualification (provisional):\n- bucket: ",
        ]
        guard let boundary = prefixes.compactMap({ text.range(of: $0)?.lowerBound }).min(),
              !text[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return String(text[..<boundary])
    }

    private static func sanitizedEntry(_ entry: AssistantConversationEntry) -> AssistantConversationEntry {
        guard entry.role == .user else { return entry }
        return AssistantConversationEntry(id: entry.id, contextID: entry.contextID, role: entry.role,
                                          text: publicUserText(entry.text), createdAt: entry.createdAt)
    }

    static func canReplace(recording: Bool, noteCapture: Bool, foregroundTurn: Bool,
                           pendingCommand: Bool, approval: Bool, launching: Bool) -> Bool {
        !recording && !noteCapture && !foregroundTurn && !pendingCommand && !approval && !launching
    }

    static func shouldDeferReplacement(hasEmbeddedProvider: Bool,
                                       managedProcessStates: [AssistantManagedProviderProcess.State],
                                       canReplace: Bool) -> Bool {
        !canReplace && (hasEmbeddedProvider || managedProcessStates.contains { $0 == .matching || $0 == .unknown })
    }

    private func update(_ mutation: (inout Document) -> Void) throws {
        if loadError != nil { throw CocoaError(.fileReadCorruptFile) }
        var next = document
        mutation(&next)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("conversation-v1.json")
        let temporaryURL = directory.appendingPathComponent(".conversation-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let data = try JSONEncoder().encode(next)
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        // There must be no throwing work after commit: a failed save cannot
        // publish a different context on disk while keeping the old provider.
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        document = next
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
