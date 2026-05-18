import Foundation
import TOMLKit

/// On-disk mutations for `.orchestrator/<id>.md` ticket files. The board UI
/// owns these flows for now; once the daemon learns about tickets, both will
/// hit the same file format.
///
/// All writes use `Data.write(to:options:.atomic)` so a crash mid-edit can't
/// leave a half-written ticket on disk.
enum TicketWriter {

    enum WriteError: Error {
        case configMissing
        case configInvalid
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
        order: Int
    ) throws -> Ticket {
        let dir = ProjectResolver.ticketsDirectory(in: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let (prefix, nextId) = try claimNextId(in: dir)
        let id = "\(prefix)-\(nextId)"

        let ticket = Ticket(
            id: id,
            title: title,
            status: status,
            priority: .medium,
            dependsOn: [],
            runId: nil,
            canceled: false,
            order: order,
            description: nil,
            body: ""
        )

        try save(ticket, in: project)
        return ticket
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
    static func ticket(_ ticket: Ticket, withDescription newDescription: String) -> Ticket {
        let newBody = TicketParser.replaceDescription(in: ticket.body, with: newDescription)
        let summary = TicketParser.extractDescription(newBody)
        return Ticket(
            id: ticket.id,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            dependsOn: ticket.dependsOn,
            runId: ticket.runId,
            canceled: ticket.canceled,
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

    // MARK: - config.toml ID claim

    /// Atomically read+bump `next_id` and return the claimed id. The write is
    /// a textual rewrite of `config.toml` — TOMLKit can't preserve comments,
    /// but config.toml only contains `prefix` and `next_id` so we rewrite the
    /// whole file from scratch.
    private static func claimNextId(in dir: URL) throws -> (prefix: String, id: Int) {
        let configURL = dir.appendingPathComponent("config.toml")
        let raw = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let table = try? TOMLTable(string: raw),
              let prefix = table["prefix"]?.tomlValue.string,
              let nextId = table["next_id"]?.tomlValue.int else {
            throw WriteError.configInvalid
        }
        let claimed = Int(nextId)
        let updated = "prefix = \"\(prefix)\"\nnext_id = \(claimed + 1)\n"
        do {
            try updated.data(using: .utf8)?.write(to: configURL, options: .atomic)
        } catch {
            throw WriteError.writeFailed(underlying: error)
        }
        return (prefix, claimed)
    }
}
