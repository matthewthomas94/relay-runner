import Foundation

struct Ticket: Identifiable, Equatable {
    let id: String
    let title: String
    let status: Status
    let priority: Priority
    let dependsOn: [String]
    let runId: Int?
    let canceled: Bool
    /// Sort key within a column. Lower = higher in the list. Optional in the
    /// on-disk schema — missing `order` falls back to the numeric portion of
    /// the ticket id (so existing tickets keep their RR-1, RR-2, … sequence
    /// without a migration). The board renumbers on drag-drop.
    let order: Int
    /// First paragraph after `## Description` in the body. Nil when the ticket
    /// has no description section. Cards may further clip this if it overflows.
    let description: String?
    /// Full body of the ticket as stored on disk (everything after the closing
    /// `---`). Held so the editor can round-trip non-Description sections like
    /// `## Acceptance criteria` without throwing them away on save.
    let body: String

    enum Status: String, CaseIterable, Equatable {
        case backlog
        case ready
        case inProgress = "in_progress"
        case done
    }

    enum Priority: String, Equatable {
        case urgent
        case high
        case medium
        case low
    }
}

enum TicketParseError: Error {
    case missingFrontmatter
    case missingField(String)
    case invalidEnum(field: String, value: String)
    case invalidType(field: String, value: String)
}

enum TicketParser {

    /// Parse a single ticket file's contents. Returns the ticket on success,
    /// or throws. Per spec: callers should log+skip on failure so one bad
    /// file doesn't take down the board.
    static func parse(contents: String) throws -> Ticket {
        guard let (frontmatter, body) = split(contents) else {
            throw TicketParseError.missingFrontmatter
        }
        let fields = parseFields(frontmatter)

        let id        = try requireString(fields, "id")
        let title     = try requireString(fields, "title")
        let statusRaw = try requireString(fields, "status")
        let priRaw    = try requireString(fields, "priority")
        let depsRaw   = try requireString(fields, "depends_on")
        let runIdRaw  = try requireString(fields, "run_id")
        let cancelRaw = try requireString(fields, "canceled")

        guard let status = Ticket.Status(rawValue: statusRaw) else {
            throw TicketParseError.invalidEnum(field: "status", value: statusRaw)
        }
        guard let priority = Ticket.Priority(rawValue: priRaw) else {
            throw TicketParseError.invalidEnum(field: "priority", value: priRaw)
        }

        return Ticket(
            id: id,
            title: title,
            status: status,
            priority: priority,
            dependsOn: parseList(depsRaw),
            runId: parseOptionalInt(runIdRaw),
            canceled: try parseBool(cancelRaw),
            order: parseOrder(fields["order"], fallbackFrom: id),
            description: extractDescription(body),
            body: body
        )
    }

    /// `order` is optional in the on-disk schema. Missing or unparseable →
    /// fall back to the numeric portion of the ticket id, so a pre-`order`
    /// repo renders in id order on first load. Tickets get explicit `order`
    /// values once they're touched by drag-drop.
    private static func parseOrder(_ raw: String?, fallbackFrom id: String) -> Int {
        if let raw, let n = Int(raw) { return n }
        if let dash = id.lastIndex(of: "-"), let n = Int(id[id.index(after: dash)...]) {
            return n
        }
        return 0
    }

    /// Replace the paragraph under `## Description` in `body` with
    /// `newDescription`. If the body has no Description section, one is
    /// inserted at the top (before any other content). If `newDescription`
    /// is empty/whitespace, the section is removed entirely. All other
    /// sections (e.g. `## Acceptance criteria`) are preserved verbatim.
    static func replaceDescription(in body: String, with newDescription: String) -> String {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.components(separatedBy: "\n")

        if let headingIdx = lines.firstIndex(where: { isDescriptionHeading($0) }) {
            // Find the end of the existing description block — first heading
            // after the Description heading, or end-of-body.
            var endIdx = lines.count
            for i in (headingIdx + 1)..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") { endIdx = i; break }
            }
            var rebuilt: [String] = Array(lines[..<headingIdx])
            if !trimmed.isEmpty {
                rebuilt.append("## Description")
                rebuilt.append("")
                rebuilt.append(trimmed)
                rebuilt.append("")
            }
            // Trim a leading blank line from the tail so we don't accumulate
            // them across edits.
            var tail = Array(lines[endIdx...])
            while tail.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                tail.removeFirst()
            }
            if !tail.isEmpty { rebuilt.append(contentsOf: tail) }
            return rebuilt.joined(separator: "\n")
        }

        if trimmed.isEmpty { return body }
        // No existing section — prepend one. Leading blank lines from the
        // original body get dropped to keep formatting tight.
        var rebuilt: [String] = ["## Description", "", trimmed, ""]
        var trimmedLines = lines
        while trimmedLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            trimmedLines.removeFirst()
        }
        rebuilt.append(contentsOf: trimmedLines)
        return rebuilt.joined(separator: "\n")
    }

    /// Everything between `## Description` and the next heading (or end of
    /// body), preserving paragraph breaks. Returns nil when the section is
    /// absent. Used by the editor — `extractDescription` is the card-summary
    /// counterpart and only returns the first paragraph.
    static func extractFullDescription(_ body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { isDescriptionHeading($0) }) else {
            return nil
        }
        var collected: [String] = []
        for line in lines[(headingIdx + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { break }
            collected.append(line)
        }
        let joined = collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// First paragraph after `## Description`. Returns nil when the section
    /// is absent or empty. A paragraph is consecutive non-blank lines.
    static func extractDescription(_ body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { isDescriptionHeading($0) }) else {
            return nil
        }
        var paragraph: [String] = []
        var seenContent = false
        for line in lines[(headingIdx + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if seenContent { break }
                continue
            }
            if trimmed.hasPrefix("#") { break }
            seenContent = true
            paragraph.append(trimmed)
        }
        let joined = paragraph.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func isDescriptionHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed == "## description" || trimmed.hasPrefix("## description ")
    }

    // MARK: - Helpers

    /// Split the file into frontmatter and body. Returns nil when frontmatter
    /// delimiters are missing.
    private static func split(_ contents: String) -> (frontmatter: String, body: String)? {
        let lines = contents.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        guard let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let frontmatter = lines[1..<endIdx].joined(separator: "\n")
        let body = lines.suffix(from: endIdx + 1).joined(separator: "\n")
        return (frontmatter, body)
    }

    private static func parseFields(_ frontmatter: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = stripQuotes(value)
        }
        return fields
    }

    private static func stripQuotes(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func requireString(_ fields: [String: String], _ key: String) throws -> String {
        guard let v = fields[key] else { throw TicketParseError.missingField(key) }
        return v
    }

    private static func parseList(_ raw: String) -> [String] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return [] }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return inner
            .components(separatedBy: ",")
            .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func parseOptionalInt(_ raw: String) -> Int? {
        let lower = raw.lowercased()
        if lower == "null" || lower.isEmpty { return nil }
        return Int(raw)
    }

    private static func parseBool(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "true":  return true
        case "false": return false
        default: throw TicketParseError.invalidType(field: "canceled", value: raw)
        }
    }
}
