import Foundation

/// On-disk mutations for `.orchestrator/<id>.md` ticket files. The board UI
/// owns these flows for now; once the daemon learns about tickets, both will
/// hit the same file format.
///
/// All writes use `Data.write(to:options:.atomic)` so a crash mid-edit can't
/// leave a half-written ticket on disk.
enum TicketWriter {

    enum WriteError: Error {
        case writeFailed(underlying: Error)
    }

    // MARK: - Create

    /// Mint a new ticket file in `.orchestrator/`. Reads `config.toml`,
    /// claims the current `next_id`, bumps the counter atomically, and
    /// writes a minimal ticket stub with the requested status.
    ///
    /// The returned `Ticket` reflects exactly what was written to disk so
    /// callers can hand it straight to an editor without re-scanning.
    static func mint(
        in project: ProjectResolver.LinkedProject,
        status: Ticket.Status,
        title: String = "Untitled",
        order: Int,
        draft: Bool = false
    ) throws -> Ticket {
        let dir = ProjectResolver.ticketsDirectory(in: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (prefix, nextId) = try BoardProjectConfig.claimNextId(forRepoAt: project.repoPath)
        let id = "\(prefix)-\(nextId)"

        let ticket = Ticket(
            id: id,
            title: title,
            status: status,
            priority: .medium,
            dependsOn: [],
            runId: nil,
            canceled: false,
            draft: draft,
            order: order,
            description: nil,
            body: ""
        )

        try save(ticket, in: project)
        return ticket
    }

    /// Mint a board-editing draft. The ticket file is real immediately, but
    /// the daemon's ready sweeper skips it until the editor save clears
    /// `draft`, which keeps create-in-ready from dispatching too early.
    static func mintDraft(
        in project: ProjectResolver.LinkedProject,
        status: Ticket.Status,
        existingTickets: [Ticket],
        title: String = "Untitled"
    ) throws -> Ticket {
        try mint(
            in: project,
            status: status,
            title: title,
            order: nextOrder(for: status, in: existingTickets),
            draft: true
        )
    }

    static func nextOrder(for status: Ticket.Status, in tickets: [Ticket]) -> Int {
        let existing = tickets.filter { $0.status == status }
        return (existing.map(\.order).max() ?? 0) + 10
    }

    // MARK: - Save / delete

    /// Rewrite a ticket file with new frontmatter and an updated description
    /// paragraph. Body sections outside `## Description` are preserved from
    /// the ticket's stored body — pass the up-to-date `Ticket` so the round
    /// trip stays clean.
    static func save(_ ticket: Ticket, in project: ProjectResolver.LinkedProject) throws {
        let url = ProjectResolver.ticketsDirectory(in: project)
            .appendingPathComponent("\(ticket.id).md")
        let rendered = render(ticket)
        do {
            try rendered.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailed(underlying: error)
        }
    }

    /// Delete a ticket file from disk. Missing files are treated as already
    /// deleted (no-op).
    static func delete(_ id: String, in project: ProjectResolver.LinkedProject) throws {
        let url = ProjectResolver.ticketsDirectory(in: project)
            .appendingPathComponent("\(id).md")
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        } catch {
            throw WriteError.writeFailed(underlying: error)
        }
    }

    // MARK: - Rendering

    /// Returns a ticket with a replaced description paragraph (body
    /// preserved). Used by the editor flow before calling `save`.
    static func ticket(
        _ ticket: Ticket,
        withDescription newDescription: String,
        acceptanceCriteria newAcceptanceCriteria: String? = nil
    ) -> Ticket {
        var newBody = TicketParser.replaceDescription(in: ticket.body, with: newDescription)
        if let newAcceptanceCriteria {
            newBody = TicketParser.replaceAcceptanceCriteria(
                in: newBody,
                with: newAcceptanceCriteria
            )
        }
        let summary = TicketParser.extractDescription(newBody)
        return Ticket(
            id: ticket.id,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            dependsOn: ticket.dependsOn,
            runId: ticket.runId,
            canceled: ticket.canceled,
            draft: ticket.draft,
            order: ticket.order,
            description: summary,
            body: newBody
        )
    }

    /// Render the ticket back to its on-disk markdown form. Frontmatter is
    /// regenerated from the struct; body is taken as-is.
    static func render(_ ticket: Ticket) -> String {
        var out = "---\n"
        out += "id: \(ticket.id)\n"
        out += "title: \(yamlString(ticket.title))\n"
        out += "status: \(ticket.status.rawValue)\n"
        out += "priority: \(ticket.priority.rawValue)\n"
        out += "depends_on: [\(ticket.dependsOn.map(yamlString).joined(separator: ", "))]\n"
        out += "run_id: \(ticket.runId.map { String($0) } ?? "null")\n"
        out += "canceled: \(ticket.canceled)\n"
        out += "order: \(ticket.order)\n"
        if ticket.draft {
            out += "draft: true\n"
        }
        out += "---\n"
        if !ticket.body.hasPrefix("\n") { out += "\n" }
        out += ticket.body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Quote a YAML scalar when it contains characters that would otherwise
    /// be ambiguous. Existing tickets in this repo store titles unquoted, but
    /// any title with a colon, leading whitespace, or YAML-special prefix
    /// needs to be quoted for the parser to round-trip cleanly.
    private static func yamlString(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let needsQuotes = s.contains(":") || s.contains("#") || s.first?.isWhitespace == true
            || s.last?.isWhitespace == true || s.hasPrefix("[") || s.hasPrefix("{")
            || s.hasPrefix("- ") || s.hasPrefix("\"") || s.hasPrefix("'")
        if !needsQuotes { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
