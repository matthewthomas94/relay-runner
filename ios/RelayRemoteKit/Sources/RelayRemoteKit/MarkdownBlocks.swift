import Foundation

/// RR-551: a ticket body split into the blocks the phone draws. A small
/// block-level splitter over Foundation's inline Markdown, so there is no
/// package dependency: headings, paragraphs, bulleted, numbered and task
/// lists, and fenced code blocks. Inline code, bold, italics and links stay
/// in each block's `AttributedString` as presentation intents and `link`s.
/// Anything else (tables, quotes, rules, HTML) reads as paragraph text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list([MarkdownListItem])
    /// A fenced block. Its text is shown as written and scrolls sideways.
    case code(String)
}

public struct MarkdownListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        /// A task item: unticked or ticked, read-only.
        case task(checked: Bool)
    }

    public var marker: Marker
    /// How far the item is nested: 0 is the outermost list.
    public var depth: Int
    public var text: AttributedString
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownListItem] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            var text = ""
            for (index, line) in paragraph.enumerated() {
                if index > 0 { text += text.hasSuffix("\n") ? "" : " " }
                if line.hasSuffix("  ") || line.hasSuffix("\\") && index < paragraph.count - 1 {
                    text += line.trimmingCharacters(in: .whitespaces).trimmingSuffix("\\") + "\n"
                } else {
                    text += line.trimmingCharacters(in: .whitespaces)
                }
            }
            blocks.append(.paragraph(inline(text)))
            paragraph = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items = []
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if let fence = fence(of: line) {
                flushParagraph()
                flushList()
                var code: [String] = []
                while index < lines.count, !isClosingFence(lines[index], matching: fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                // A blank line between items of one list does not end the list.
                if let next = lines[index...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   let last = items.last,
                   listItem(in: next).map({ isNumbered($0.marker) == isNumbered(last.marker) })
                       ?? (indent(of: next) >= 2) {
                    continue
                }
                flushList()
                continue
            }
            if let (level, text) = heading(in: line) {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: level, text: inline(text)))
                continue
            }
            if let item = listItem(in: line) {
                flushParagraph()
                items.append(item)
                continue
            }
            if !items.isEmpty, indent(of: line) >= 2, paragraph.isEmpty {
                // A wrapped line of the item above.
                let last = items.removeLast()
                var text = last.text
                text.append(AttributedString(" ") + inline(line.trimmingCharacters(in: .whitespaces)))
                items.append(MarkdownListItem(marker: last.marker, depth: last.depth, text: text))
                continue
            }
            flushList()
            paragraph.append(stripQuote(line))
        }
        flushParagraph()
        flushList()
        return blocks
    }

    /// Foundation's inline Markdown, keeping spaces and line breaks as written.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: Lines

    private static func isNumbered(_ marker: MarkdownListItem.Marker) -> Bool {
        if case .number = marker { return true }
        return false
    }

    private static func indent(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    private static func fence(of line: String) -> String? {
        guard indent(of: line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return String(trimmed.prefix(while: { $0 == marker.first! }))
        }
        return nil
    }

    private static func isClosingFence(_ line: String, matching fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(fence) && trimmed.allSatisfy { $0 == fence.first! }
    }

    private static func heading(in line: String) -> (Int, String)? {
        guard indent(of: line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        // An optional closing run of #s is not part of the text.
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        return (hashes, text)
    }

    private static func listItem(in line: String) -> MarkdownListItem? {
        let depth = indent(of: line) / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var marker: MarkdownListItem.Marker
        var rest: Substring
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            marker = .bullet
            rest = trimmed.dropFirst(2)
        } else if let match = trimmed.range(of: #"^\d{1,9}[.)] "#, options: .regularExpression) {
            let digits = trimmed[match].prefix(while: \.isNumber)
            marker = .number(Int(digits) ?? 1)
            rest = trimmed[match.upperBound...]
        } else {
            return nil
        }
        let body = rest.trimmingCharacters(in: .whitespaces)
        for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where body.hasPrefix(box) || body == box.trimmingCharacters(in: .whitespaces) {
            marker = .task(checked: checked)
            return MarkdownListItem(marker: marker, depth: depth, text: inline(String(body.dropFirst(box.count))))
        }
        return MarkdownListItem(marker: marker, depth: depth, text: inline(body))
    }

    private static func stripQuote(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return line }
        return String(trimmed.dropFirst().drop(while: { $0 == " " }))
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
