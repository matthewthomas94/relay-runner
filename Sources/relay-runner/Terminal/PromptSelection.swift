import AppKit
import SwiftTerm

/// The hosted CLI's prompt as it is drawn on screen, read back from the
/// terminal grid so Shift-arrows can select inside it.
///
/// Claude Code and Codex draw their own input box and select nothing on
/// Shift-arrows, so the terminal draws the selection itself and edits it by
/// sending plain movement and deletion keys. The layout maps every prompt
/// character to the cell the CLI's caret occupies in front of it. Anything
/// it cannot account for exactly returns nil, and the key falls back to
/// plain forwarding.
struct RelayPromptLayout: Equatable {
    enum Style: Equatable {
        case claude
        case codex
    }

    struct Cell: Equatable {
        var character: Character
        /// 2 for a wide character, 0 for the cell a wide character covers.
        var width = 1
        /// Dim cells are placeholder or suggestion text, not typed input.
        var dim = false
    }

    struct Position: Equatable, Hashable {
        var col: Int
        var row: Int
    }

    /// The prompt text, including the space or newline at each wrap.
    let characters: [Character]
    /// The caret cell in front of each character, then the end: one entry
    /// more than `characters`.
    let stops: [Position]
    /// Cells drawn for each character; 0 for a wrap space with no cell.
    let widths: [Int]
    /// Screen rows the prompt occupies, including a caret row below it.
    let rows: ClosedRange<Int>
    /// What those rows showed, to notice when the CLI redraws the prompt.
    let rowTexts: [String]
    /// The character the caret was in front of when the screen was read.
    let caret: Int

    var count: Int { characters.count }

    /// Prompt chips stand for text the screen does not show.
    private static let chipMarkers = ["[Pasted text #", "[Image #", "[Pasted Content"]
    /// Prompt text starts after the two-cell `❯ ` / `› ` margin.
    private static let firstColumn = 2

    /// Reads the prompt around the cursor. Claude Code frames it with rules
    /// above and below; Codex ends it at a blank line above its footer.
    static func parse(
        style: Style,
        cols: Int,
        rows: Int,
        cursor: Position,
        cell: (_ col: Int, _ row: Int) -> Cell?
    ) -> RelayPromptLayout? {
        let first = firstColumn
        let width = style == .claude ? cols - 4 : cols - 3
        guard width >= 8, (0..<rows).contains(cursor.row), (0..<cols).contains(cursor.col) else {
            return nil
        }

        func at(_ col: Int, _ row: Int) -> Cell { cell(col, row) ?? Cell(character: " ") }
        func isBlank(_ cell: Cell) -> Bool { Self.isBlank(cell) }
        func marginIsBlank(_ row: Int) -> Bool { isBlank(at(0, row)) && isBlank(at(1, row)) }
        func rowIsBlank(_ row: Int) -> Bool { (0..<cols).allSatisfy { isBlank(at($0, row)) } }
        func isRule(_ row: Int) -> Bool { at(0, row).character == "─" }
        let glyph: Character = style == .claude ? "❯" : "›"
        func isPromptStart(_ row: Int) -> Bool {
            let mark = at(0, row)
            return mark.character == glyph && !mark.dim && isBlank(at(1, row))
        }
        func rowText(_ row: Int) -> String { Self.rowText(row, cols: cols, cell: cell) }

        var top = cursor.row
        while !isPromptStart(top) {
            guard marginIsBlank(top), top > 0 else { return nil }
            top -= 1
        }
        if style == .claude {
            guard top > 0, isRule(top - 1) else { return nil }
        }
        var bottom = top
        while true {
            let next = bottom + 1
            guard next < rows else { return nil }
            if style == .claude ? isRule(next) : rowIsBlank(next) { break }
            guard marginIsBlank(next) else { return nil }
            bottom = next
        }
        let rowTexts = (top...bottom).map(rowText)
        guard !rowTexts.contains(where: { text in chipMarkers.contains { text.contains($0) } }) else {
            return nil
        }

        typealias Glyph = (character: Character, col: Int, width: Int)
        var lines: [[Glyph]] = []
        var used: [Int] = []
        for row in top...bottom {
            var end = first
            for col in first..<cols {
                let cell = at(col, row)
                if cell.width != 0, !isBlank(cell) { end = col + max(cell.width, 1) }
            }
            guard end - first <= width else { return nil }
            var line: [Glyph] = []
            var col = first
            while col < end {
                let cell = at(col, row)
                if cell.width == 0 {
                    col += 1
                    continue
                }
                let blank = isBlank(cell)
                let span = blank ? 1 : max(cell.width, 1)
                line.append((blank ? " " : cell.character, col, span))
                col += span
            }
            lines.append(line)
            used.append(end - first)
        }

        func leadingWord(_ line: [Glyph]) -> Int {
            line.prefix { $0.character != " " }.reduce(0) { $0 + $1.width }
        }
        func trailingWord(_ line: [Glyph]) -> Int {
            line.reversed().prefix { $0.character != " " }.reduce(0) { $0 + $1.width }
        }

        var characters: [Character] = []
        var stops: [Position] = []
        var widths: [Int] = []
        func append(_ character: Character, _ stop: Position, _ cells: Int) {
            characters.append(character)
            stops.append(stop)
            widths.append(cells)
        }
        for (index, line) in lines.enumerated() {
            let row = top + index
            for glyph in line { append(glyph.character, Position(col: glyph.col, row: row), glyph.width) }
            guard index + 1 < lines.count else { break }
            let next = lines[index + 1]
            if used[index] < width {
                // The CLI moved the next word down, or the line ended here.
                let fits = used[index] + 1 + leadingWord(next) <= width
                append(fits ? "\n" : " ", Position(col: first + used[index], row: row), 1)
            } else if let last = line.last, last.character != " ",
                      let start = next.first, start.character != " ",
                      trailingWord(line) + leadingWord(next) <= width {
                // Claude wraps the space after a word that ends the row
                // without drawing it; its caret shows at the next row's start.
                append(" ", Position(col: first, row: row + 1), 0)
            }
        }

        var lastRow = bottom
        if cursor.row == bottom {
            // Codex shows typed trailing spaces only through the caret.
            while first + used[used.count - 1] < cursor.col {
                append(" ", Position(col: first + used[used.count - 1], row: bottom), 1)
                used[used.count - 1] += 1
            }
        }
        if style == .codex, used[used.count - 1] == width {
            // A full last row puts Codex's end caret on the blank row below.
            lastRow = bottom + 1
            stops.append(Position(col: first, row: lastRow))
        } else {
            guard cursor.row <= bottom else { return nil }
            stops.append(Position(col: first + used[used.count - 1], row: bottom))
        }

        let matches = stops.indices.filter { stops[$0] == cursor }
        guard matches.count == 1, let caret = matches.first else { return nil }
        return RelayPromptLayout(
            characters: characters,
            stops: stops,
            widths: widths,
            rows: top...lastRow,
            rowTexts: rowTexts + (lastRow > bottom ? [rowText(lastRow)] : []),
            caret: caret
        )
    }

    /// Whether the screen still shows this prompt.
    func isShown(cols: Int, cell: (_ col: Int, _ row: Int) -> Cell?) -> Bool {
        rows.map { Self.rowText($0, cols: cols, cell: cell) } == rowTexts
    }

    private static func isBlank(_ cell: Cell) -> Bool {
        cell.dim || cell.character == "\0" || cell.character == " " || cell.character == "\u{00A0}"
    }

    private static func rowText(_ row: Int, cols: Int, cell: (_ col: Int, _ row: Int) -> Cell?) -> String {
        String((0..<cols).map { col -> Character in
            let cell = cell(col, row) ?? Cell(character: " ")
            return isBlank(cell) ? " " : cell.character
        })
    }

    func text(_ range: Range<Int>) -> String { String(characters[range]) }

    /// Where Option-arrow lands: over non-word characters, then a word.
    func wordTarget(from index: Int, forward: Bool) -> Int {
        var target = index
        if forward {
            while target < count, !Self.isWordCharacter(characters[target]) { target += 1 }
            while target < count, Self.isWordCharacter(characters[target]) { target += 1 }
        } else {
            while target > 0, !Self.isWordCharacter(characters[target - 1]) { target -= 1 }
            while target > 0, Self.isWordCharacter(characters[target - 1]) { target -= 1 }
        }
        return target
    }

    /// Where Cmd-arrow lands: the start or end of the prompt line.
    func lineTarget(from index: Int, forward: Bool) -> Int {
        if forward {
            return characters[index...].firstIndex(of: "\n") ?? count
        }
        return characters[..<index].lastIndex(of: "\n").map { $0 + 1 } ?? 0
    }

    /// Cells to highlight for a range, merged into one run per row.
    func highlightRuns(_ range: Range<Int>) -> [(row: Int, col: Int, width: Int)] {
        var runs: [(row: Int, col: Int, width: Int)] = []
        for index in range where widths[index] > 0 {
            let stop = stops[index]
            if let last = runs.last, last.row == stop.row, last.col + last.width == stop.col {
                runs[runs.count - 1].width += widths[index]
            } else {
                runs.append((stop.row, stop.col, widths[index]))
            }
        }
        return runs
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// Plain arrow presses, which both CLIs apply in one burst.
    static func moveBytes(count: Int, forward: Bool, applicationCursor: Bool) -> [UInt8] {
        let key: [UInt8] = [27, applicationCursor ? 79 : 91, forward ? 67 : 68]
        return Array([[UInt8]](repeating: key, count: count).joined())
    }

    /// Deletes the characters between the caret and the anchor: Backspace
    /// when the caret is after them, Forward Delete when it is before.
    static func deleteBytes(extent: Int) -> [UInt8] {
        if extent > 0 {
            return [UInt8](repeating: 127, count: extent)
        }
        return Array([[UInt8]](repeating: [27, 91, 51, 126], count: -extent).joined())
    }
}

/// A selection the terminal draws over the prompt. The CLI's own caret
/// follows its moving end through plain arrow presses.
struct RelayPromptSelection {
    enum Unit {
        case character, word, line
    }

    /// Presses sent that the screen has not shown yet.
    struct Pending {
        var expected: Int
        /// A press onto the first or last character, held back until
        /// `expected` shows, so a press the CLI ignores at the end is noticed.
        var finalStep: Int?
        var deadline: Date
    }

    var layout: RelayPromptLayout
    var anchor: Int
    var caret: Int
    /// Where the presses sent so far put the CLI's caret.
    var sentCaret: Int
    var pending: Pending?

    var range: Range<Int> { min(anchor, caret)..<max(anchor, caret) }
}

// MARK: Prompt selection

extension RelayTerminalView {
    var hasPromptSelection: Bool { promptSelection.map { !$0.range.isEmpty } ?? false }

    /// Shift-arrows select in the hosted CLI's prompt. With a selection,
    /// Delete removes it, typing replaces it, plain arrows collapse it and
    /// other keys clear it. True when the key is used up here.
    func handlePromptSelectionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let arrow = event.keyCode == 123 || event.keyCode == 124
        if arrow {
            let unit: RelayPromptSelection.Unit?
            switch flags {
            case .shift: unit = .character
            case [.shift, .option]: unit = .word
            case [.shift, .command]: unit = .line
            default: unit = nil
            }
            if let unit {
                return extendPromptSelection(forward: event.keyCode == 124, by: unit)
            }
        }
        promptSelectionFailed = false
        guard promptSelection != nil else { return false }
        if let command = Self.keyCommand(for: event) {
            // Copy and paste read the selection in `copy(_:)` / `paste(_:)`.
            if command != .copy, command != .paste { settlePromptSelection() }
            return false
        }
        if arrow {
            if flags.isEmpty { return collapsePromptSelection(forward: event.keyCode == 124) }
        } else if event.keyCode == 51 || event.keyCode == 117, !flags.contains(.control) {
            return deletePromptSelection()
        } else if Self.typesText(event) {
            deletePromptSelection()
            return false
        } else if event.characters?.isEmpty == true, !flags.contains(.command), !flags.contains(.control) {
            // A dead key composes into the next key, which replaces the selection.
            return false
        }
        settlePromptSelection()
        return false
    }

    /// New output may be the CLI redrawing its prompt after a press.
    func providerOutputDidArrive() {
        guard promptSelection != nil else { return }
        let soon = Date().addingTimeInterval(0.04)
        if let scheduled = promptSelectionCheckDate, scheduled <= soon { return }
        schedulePromptSelectionCheck(after: 0.04)
    }

    func clearPromptSelection() {
        promptSelection = nil
        promptSelectionCheck?.cancel()
        promptSelectionCheck = nil
        promptSelectionCheckDate = nil
        drawPromptSelection()
    }

    /// Deletes the selected text through the CLI. False, with the selection
    /// cleared, when there is nothing selected or the screen is not yet
    /// showing what was sent.
    @discardableResult
    func deletePromptSelection() -> Bool {
        guard hasPromptSelection else {
            settlePromptSelection()
            return false
        }
        guard resolvePromptSelection(), let selection = promptSelection else {
            clearPromptSelection()
            return false
        }
        send(data: ArraySlice(RelayPromptLayout.deleteBytes(extent: selection.caret - selection.anchor)))
        clearPromptSelection()
        return true
    }

    /// Text that would type into the prompt: no Cmd or Control, no Option
    /// acting as Meta, and a printable character.
    static func typesText(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.control) else { return false }
        if flags.contains(.option), optionActsAsMeta(rawModifierFlags: flags.rawValue) { return false }
        guard let scalar = event.characters?.unicodeScalars.first?.value else { return false }
        return scalar >= 0x20 && scalar != 0x7F && !(0xF700...0xF8FF).contains(scalar)
    }

    private func extendPromptSelection(forward: Bool, by unit: RelayPromptSelection.Unit) -> Bool {
        guard promptStyle != nil, !promptSelectionFailed, !inputIsBuffered(), isShowingLatestOutput else {
            clearPromptSelection()
            return false
        }
        var selection: RelayPromptSelection
        if let current = promptSelection {
            selection = current
        } else {
            guard let layout = readPromptLayout() else { return false }
            if selectionActive { selectNone() }
            selection = RelayPromptSelection(layout: layout, anchor: layout.caret, caret: layout.caret, sentCaret: layout.caret)
        }
        let layout = selection.layout
        let target: Int
        switch unit {
        case .character: target = min(max(selection.caret + (forward ? 1 : -1), 0), layout.count)
        case .word: target = layout.wordTarget(from: selection.caret, forward: forward)
        case .line: target = layout.lineTarget(from: selection.caret, forward: forward)
        }
        guard target != selection.caret else {
            promptSelection = selection
            drawPromptSelection()
            return true
        }
        // The CLI ignores presses past either end, so a burst onto an end
        // stops one short until the screen confirms it.
        let atEnd = target == 0 || target == layout.count
        let staged = atEnd && (selection.pending != nil || abs(target - selection.sentCaret) > 1)
        var goal = target
        if staged {
            goal = target == 0 ? 1 : layout.count - 1
            guard layout.stops[goal] != layout.stops[target] else {
                clearPromptSelection()
                return false
            }
        }
        sendPromptMoves(from: selection.sentCaret, to: goal)
        selection.caret = target
        selection.sentCaret = goal
        selection.pending = .init(expected: goal, finalStep: staged ? target : nil, deadline: Date().addingTimeInterval(1))
        promptSelection = selection
        drawPromptSelection()
        schedulePromptSelectionCheck(after: 0.15)
        return true
    }

    private func collapsePromptSelection(forward: Bool) -> Bool {
        guard hasPromptSelection else {
            settlePromptSelection()
            return false
        }
        guard resolvePromptSelection(), let selection = promptSelection else {
            clearPromptSelection()
            return false
        }
        sendPromptMoves(from: selection.sentCaret, to: forward ? selection.range.upperBound : selection.range.lowerBound)
        clearPromptSelection()
        return true
    }

    /// Ends the selection with the CLI's caret where it was drawn.
    private func settlePromptSelection() {
        resolvePromptSelection()
        clearPromptSelection()
    }

    /// Sends a held-back end press once the screen shows the presses before
    /// it. False when the CLI has not caught up or drew something else.
    @discardableResult
    private func resolvePromptSelection() -> Bool {
        guard var selection = promptSelection, !inputIsBuffered(),
              promptIsShown(selection.layout, caret: selection.pending?.expected ?? selection.sentCaret) else {
            return false
        }
        if let final = selection.pending?.finalStep {
            sendPromptMoves(from: selection.sentCaret, to: final)
            selection.sentCaret = final
        }
        selection.pending = nil
        promptSelection = selection
        return true
    }

    private func checkPromptSelection() {
        promptSelectionCheck = nil
        promptSelectionCheckDate = nil
        guard var selection = promptSelection else { return }
        let shown = promptIsShown(selection.layout, caret: selection.pending?.expected ?? selection.sentCaret)
        guard let pending = selection.pending else {
            if !shown { clearPromptSelection() }
            return
        }
        if shown, let final = pending.finalStep {
            sendPromptMoves(from: selection.sentCaret, to: final)
            selection.sentCaret = final
            selection.pending = .init(expected: final, finalStep: nil, deadline: Date().addingTimeInterval(1))
            promptSelection = selection
            schedulePromptSelectionCheck(after: 0.15)
        } else if shown {
            selection.pending = nil
            promptSelection = selection
        } else if Date() >= pending.deadline {
            // The CLI did not move as expected; plain forwarding from here.
            clearPromptSelection()
            promptSelectionFailed = true
        } else {
            schedulePromptSelectionCheck(after: 0.05)
        }
    }

    private func schedulePromptSelectionCheck(after delay: TimeInterval) {
        promptSelectionCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.checkPromptSelection() }
        promptSelectionCheck = check
        promptSelectionCheckDate = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

    private func sendPromptMoves(from start: Int, to end: Int) {
        guard end != start else { return }
        sendNavigationShortcut(RelayPromptLayout.moveBytes(
            count: abs(end - start),
            forward: end > start,
            applicationCursor: getTerminal().applicationCursor
        ))
    }

    private var isShowingLatestOutput: Bool { !canScroll || scrollPosition >= 1 }

    private func readPromptLayout() -> RelayPromptLayout? {
        guard let promptStyle else { return nil }
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        return RelayPromptLayout.parse(
            style: promptStyle,
            cols: terminal.cols,
            rows: terminal.rows,
            cursor: .init(col: cursor.x, row: cursor.y),
            cell: promptCell
        )
    }

    private func promptIsShown(_ layout: RelayPromptLayout, caret: Int) -> Bool {
        guard isShowingLatestOutput else { return false }
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        return layout.stops[caret] == .init(col: cursor.x, row: cursor.y)
            && layout.isShown(cols: terminal.cols, cell: promptCell)
    }

    private func promptCell(col: Int, row: Int) -> RelayPromptLayout.Cell? {
        let terminal = getTerminal()
        guard let data = terminal.getCharData(col: col, row: row) else { return nil }
        return .init(
            character: terminal.getCharacter(for: data),
            width: Int(data.width),
            dim: data.attribute.style.contains(.dim)
        )
    }

    private func drawPromptSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        promptSelectionLayers.forEach { $0.removeFromSuperlayer() }
        promptSelectionLayers = []
        guard let selection = promptSelection, let layer else { return }
        // SwiftTerm's cell size is internal; it uses the "W" advance,
        // snapped to pixels, and a height that fills the rows exactly.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellWidth = max(1, ceil(advance * scale) / scale)
        let cellHeight = getOptimalFrameSize().height / CGFloat(max(getTerminal().rows, 1))
        let color = selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor
        for run in selection.layout.highlightRuns(selection.range) {
            let highlight = CALayer()
            highlight.backgroundColor = color
            highlight.zPosition = 1_000
            highlight.frame = CGRect(
                x: cellWidth * CGFloat(run.col),
                y: bounds.height - cellHeight * CGFloat(run.row + 1),
                width: cellWidth * CGFloat(run.width),
                height: cellHeight
            )
            layer.addSublayer(highlight)
            promptSelectionLayers.append(highlight)
        }
    }
}
