import Foundation

struct Ticket: Identifiable, Equatable {
    let id: String
    let title: String
    let status: Status
    let priority: Priority
    let dependsOn: [String]
    let runId: Int?
    let canceled: Bool
    let workerModel: String?
    let workerEffort: String?
    let workerSizingRationale: String?
    let workerProviderNotes: String?
    /// Board-created tickets are written before the editor opens so they get a
    /// real id immediately. While `draft` is true, the daemon must not sweep a
    /// ready ticket into a worker; saving the editor clears the flag.
    let draft: Bool
    /// Sort key within a column. Lower = higher in the list. Optional in the
    /// on-disk schema — missing `order` falls back to the numeric portion of
    /// the ticket id (so existing tickets keep their RR-1, RR-2, ... sequence
    /// without a migration).
    let order: Int
    /// Owning ticket file's modification time. Nil for tickets that have not
    /// been scanned from disk yet.
    let modifiedAt: Date?
    /// First paragraph after `## Description` in the body. Nil when the ticket
    /// has no description section. Cards may further clip this if it overflows.
    let description: String?
    /// Full body of the ticket as stored on disk (everything after the closing
    /// `---`). Held so the editor can round-trip non-Description sections like
    /// `## Acceptance criteria` without throwing them away on save.
    let body: String

    init(
        id: String,
        title: String,
        status: Status,
        priority: Priority,
        dependsOn: [String],
        runId: Int?,
        canceled: Bool,
        workerModel: String? = nil,
        workerEffort: String? = nil,
        workerSizingRationale: String? = nil,
        workerProviderNotes: String? = nil,
        draft: Bool = false,
        order: Int,
        modifiedAt: Date? = nil,
        description: String?,
        body: String
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.dependsOn = dependsOn
        self.runId = runId
        self.canceled = canceled
        self.workerModel = workerModel
        self.workerEffort = workerEffort
        self.workerSizingRationale = workerSizingRationale
        self.workerProviderNotes = workerProviderNotes
        self.draft = draft
        self.order = order
        self.modifiedAt = modifiedAt
        self.description = description
        self.body = body
    }

    enum Status: String, CaseIterable, Equatable, Hashable {
        case backlog
        case ready
        case inProgress = "in_progress"
        case done
    }

    enum Priority: String, CaseIterable, Equatable, Hashable {
        case urgent
        case high
        case medium
        case low
    }
}

extension Ticket {
    static func boardOrder(_ lhs: Ticket, _ rhs: Ticket) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return newestFirst(lhs, rhs)
    }

    static func orderBetween(previous: Int?, next: Int?) -> Int? {
        switch (previous, next) {
        case let (.some(previous), .some(next)):
            guard next - previous > 1 else { return nil }
            return previous + ((next - previous) / 2)
        case let (.some(previous), .none):
            return previous + 10
        case let (.none, .some(next)):
            return next - 10
        case (.none, .none):
            return 10
        }
    }

    static func newestFirst(_ lhs: Ticket, _ rhs: Ticket) -> Bool {
        newestFirst(
            lhsModifiedAt: lhs.modifiedAt,
            lhsID: lhs.id,
            lhsTitle: lhs.title,
            rhsModifiedAt: rhs.modifiedAt,
            rhsID: rhs.id,
            rhsTitle: rhs.title
        )
    }

    static func newestFirst(
        lhsModifiedAt: Date?,
        lhsID: String?,
        lhsTitle: String?,
        rhsModifiedAt: Date?,
        rhsID: String?,
        rhsTitle: String?
    ) -> Bool {
        if let lhsModifiedAt, let rhsModifiedAt, lhsModifiedAt != rhsModifiedAt {
            return lhsModifiedAt > rhsModifiedAt
        }

        let left = ticketNumber(lhsID)
        let right = ticketNumber(rhsID)
        if left != right { return left > right }
        let leftID = lhsID ?? ""
        let rightID = rhsID ?? ""
        if leftID != rightID { return leftID > rightID }
        return (lhsTitle ?? "").localizedStandardCompare(rhsTitle ?? "") == .orderedAscending
    }

    private static func ticketNumber(_ id: String?) -> Int {
        guard let id else { return Int.min }
        guard let dash = id.lastIndex(of: "-"),
              let number = Int(id[id.index(after: dash)...]) else {
            return Int.min
        }
        return number
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
    static func parse(contents: String, modifiedAt: Date? = nil) throws -> Ticket {
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
        let draftRaw  = fields["draft"]

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
            canceled: try parseBool(cancelRaw, field: "canceled"),
            workerModel: optionalString(fields["worker_model"]),
            workerEffort: optionalString(fields["worker_effort"]),
            workerSizingRationale: optionalString(fields["worker_sizing_rationale"]),
            workerProviderNotes: optionalString(fields["worker_provider_notes"]),
            draft: try draftRaw.map { try parseBool($0, field: "draft") } ?? false,
            order: parseOrder(fields["order"], fallbackFrom: id),
            modifiedAt: modifiedAt,
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
        extractSection(named: "Description", in: body)
    }

    static func extractAcceptanceCriteria(_ body: String) -> String? {
        extractSection(named: "Acceptance criteria", in: body)
    }

    static func replaceAcceptanceCriteria(in body: String, with newAcceptanceCriteria: String) -> String {
        replaceSection(named: "Acceptance criteria", in: body, with: newAcceptanceCriteria, insertAtTop: false)
    }

    static func extractSection(named heading: String, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { isHeading($0, named: heading) }) else {
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
        isHeading(line, named: "Description")
    }

    private static func isHeading(_ line: String, named heading: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        let target = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "## \(target)" || trimmed.hasPrefix("## \(target) ")
    }

    private static func replaceSection(
        named heading: String,
        in body: String,
        with newContent: String,
        insertAtTop: Bool
    ) -> String {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.components(separatedBy: "\n")

        if let headingIdx = lines.firstIndex(where: { isHeading($0, named: heading) }) {
            var endIdx = lines.count
            for i in (headingIdx + 1)..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") { endIdx = i; break }
            }

            var rebuilt: [String] = Array(lines[..<headingIdx])
            if !trimmed.isEmpty {
                rebuilt.append("## \(heading)")
                rebuilt.append("")
                rebuilt.append(trimmed)
                rebuilt.append("")
            }
            var tail = Array(lines[endIdx...])
            while tail.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                tail.removeFirst()
            }
            if !tail.isEmpty { rebuilt.append(contentsOf: tail) }
            return rebuilt.joined(separator: "\n")
        }

        guard !trimmed.isEmpty else { return body }

        if insertAtTop {
            var rebuilt: [String] = ["## \(heading)", "", trimmed, ""]
            var trimmedLines = lines
            while trimmedLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                trimmedLines.removeFirst()
            }
            rebuilt.append(contentsOf: trimmedLines)
            return rebuilt.joined(separator: "\n")
        }

        var rebuilt = lines
        while rebuilt.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            rebuilt.removeLast()
        }
        if !rebuilt.isEmpty { rebuilt.append("") }
        rebuilt.append("## \(heading)")
        rebuilt.append("")
        rebuilt.append(trimmed)
        return rebuilt.joined(separator: "\n")
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

    private static func optionalString(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
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

    private static func parseBool(_ raw: String, field: String) throws -> Bool {
        switch raw.lowercased() {
        case "true":  return true
        case "false": return false
        default: throw TicketParseError.invalidType(field: field, value: raw)
        }
    }
}
