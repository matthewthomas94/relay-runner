import Foundation

struct Ticket: Identifiable, Equatable {
    let id: String
    let title: String
    let status: Status
    let priority: Priority
    let dependsOn: [String]
    let runId: Int?
    let canceled: Bool
    /// First paragraph after `## Description` in the body. Nil when the ticket
    /// has no description section. Cards may further clip this if it overflows.
    let description: String?

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
            description: extractDescription(body)
        )
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
