import AppKit
import SwiftTerm
import XCTest
@testable import relay_runner

final class RelayPromptLayoutTests: XCTestCase {
    private typealias Position = RelayPromptLayout.Position

    func testClaudeWrappedWordsKeepTheirSpacesAndCaretStops() throws {
        let layout = try XCTUnwrap(parse(.claude, cols: 14, cursor: Position(col: 7, row: 3), [
            "──────────────",
            "❯ hello",
            "  brave",
            "  world",
            "──────────────",
        ]))
        XCTAssertEqual(layout.text(0..<layout.count), "hello brave world")
        XCTAssertEqual(layout.caret, 17)
        XCTAssertEqual(layout.stops[6], Position(col: 2, row: 2))
        XCTAssertEqual(layout.wordTarget(from: 17, forward: false), 12)
        XCTAssertEqual(layout.lineTarget(from: 17, forward: false), 0)
        XCTAssertEqual(layout.highlightRuns(3..<8).map { [$0.row, $0.col, $0.width] }, [[1, 5, 3], [2, 2, 2]])
    }

    func testClaudeLineBreaksAreNewlines() throws {
        let layout = try XCTUnwrap(parse(.claude, cols: 14, cursor: Position(col: 3, row: 2), [
            "──────────────",
            "❯ ab",
            "  cd",
            "──────────────",
        ]))
        XCTAssertEqual(layout.text(0..<layout.count), "ab\ncd")
        XCTAssertEqual(layout.caret, 4)
        XCTAssertEqual(layout.lineTarget(from: 4, forward: false), 3)
        XCTAssertEqual(layout.lineTarget(from: 1, forward: true), 2)
    }

    func testClaudeFullRowHidesTheSpaceBeforeTheNextWord() throws {
        let layout = try XCTUnwrap(parse(.claude, cols: 14, cursor: Position(col: 4, row: 2), [
            "──────────────",
            "❯ abcd efghi",
            "  jk",
            "──────────────",
        ]))
        XCTAssertEqual(layout.text(0..<layout.count), "abcd efghi jk")
        XCTAssertEqual(layout.widths[10], 0)
        XCTAssertEqual(layout.caret, 13)
        XCTAssertEqual(layout.highlightRuns(9..<12).map { [$0.row, $0.col, $0.width] }, [[1, 11, 1], [2, 2, 1]])
    }

    func testCodexFullLastRowPutsTheEndCaretBelowIt() throws {
        let layout = try XCTUnwrap(parse(.codex, cols: 13, cursor: Position(col: 2, row: 1), [
            "› 0123456789",
            "",
            "  footer",
        ]))
        XCTAssertEqual(layout.count, 10)
        XCTAssertEqual(layout.caret, 10)
        XCTAssertEqual(layout.rows, 0...1)
    }

    func testCodexPlaceholderIsNotPromptText() throws {
        let dim = Set((2..<11).map { Position(col: $0, row: 0) })
        let layout = try XCTUnwrap(parse(.codex, cols: 20, cursor: Position(col: 2, row: 0), [
            "› Ask Codex",
            "",
        ], dim: dim))
        XCTAssertEqual(layout.count, 0)
        XCTAssertEqual(layout.caret, 0)
    }

    func testUnreadablePromptsAreRefused() {
        XCTAssertNil(parse(.claude, cols: 40, cursor: Position(col: 30, row: 1), [
            "────────────────────────────────────────",
            "❯ [Pasted text #1 +20 lines]",
            "────────────────────────────────────────",
        ]), "A chip hides text")
        XCTAssertNil(parse(.claude, cols: 20, cursor: Position(col: 3, row: 0), [
            "$ ls",
            "────────────────────",
        ]), "No prompt around the cursor")
        XCTAssertNil(parse(.claude, cols: 20, cursor: Position(col: 9, row: 1), [
            "────────────────────",
            "❯ ab",
            "  cd",
            "────────────────────",
        ]), "The cursor is past the end of a row that is not the last")
    }

    func testMoveAndDeleteBytes() {
        XCTAssertEqual(RelayPromptLayout.moveBytes(count: 2, forward: false, applicationCursor: false), [27, 91, 68, 27, 91, 68])
        XCTAssertEqual(RelayPromptLayout.moveBytes(count: 1, forward: true, applicationCursor: true), [27, 79, 67])
        XCTAssertEqual(RelayPromptLayout.deleteBytes(extent: 2), [127, 127])
        XCTAssertEqual(RelayPromptLayout.deleteBytes(extent: -1), [27, 91, 51, 126])
    }

    private func parse(
        _ style: RelayPromptLayout.Style,
        cols: Int,
        cursor: Position,
        _ lines: [String],
        dim: Set<Position> = []
    ) -> RelayPromptLayout? {
        let grid = lines.map { Array($0) }
        return RelayPromptLayout.parse(style: style, cols: cols, rows: lines.count, cursor: cursor) { col, row in
            guard grid.indices.contains(row) else { return nil }
            let line = grid[row]
            return .init(
                character: line.indices.contains(col) ? line[col] : " ",
                dim: dim.contains(Position(col: col, row: row))
            )
        }
    }
}

final class RelayPromptSelectionTests: XCTestCase {
    private var view: RelayTerminalView!
    private var delegate: PromptPayloadDelegate!

    override func setUpWithError() throws {
        view = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.wantsLayer = true
        delegate = PromptPayloadDelegate()
        view.terminalDelegate = delegate
        view.promptStyle = .claude
        let cols = view.getTerminal().cols
        guard cols >= 30 else { throw XCTSkip("The test terminal is too narrow") }
        // A Claude prompt reading "hello brave world", caret at the end.
        let rule = String(repeating: "─", count: cols)
        view.feed(text: "\u{1B}[2J\u{1B}[H\(rule)\r\n❯ hello brave world\r\n\(rule)\u{1B}[2;20H")
    }

    override func tearDown() {
        view.clearPromptSelection()
        view = nil
        delegate = nil
    }

    func testShiftArrowsSelectThroughPlainMovesAndDeleteRemovesTheSelection() {
        for _ in 0..<3 { XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift]))) }
        XCTAssertEqual(delegate.payloads, [left(1), left(1), left(1)])
        XCTAssertEqual(view.promptSelectionLayers.count, 1)

        cliMovesCaret(by: -3)
        XCTAssertTrue(view.handlePromptSelectionKey(key(51, [], "\u{7F}")))
        // The caret is before the selection, so it deletes forward.
        XCTAssertEqual(delegate.payloads.last, RelayPromptLayout.deleteBytes(extent: -3))
        XCTAssertNil(view.promptSelection)
        XCTAssertTrue(view.promptSelectionLayers.isEmpty)
    }

    func testCopyReadsTheSelectedPromptText() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift, .option])))
        XCTAssertEqual(delegate.payloads, [left(5)])
        cliMovesCaret(by: -5)

        let copy = key(8, [.command], "c")
        XCTAssertFalse(view.handlePromptSelectionKey(copy))
        XCTAssertTrue(view.handleKeyCommand(copy))
        XCTAssertEqual(pasteboard.string(forType: .string), "world")
        XCTAssertTrue(view.hasPromptSelection, "Copying keeps the selection")
    }

    func testTypingReplacesTheSelection() {
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift])))
        cliMovesCaret(by: -1)
        XCTAssertFalse(view.handlePromptSelectionKey(key(7, [], "x")), "The typed key still reaches the CLI")
        XCTAssertEqual(delegate.payloads.last, RelayPromptLayout.deleteBytes(extent: -1))
        XCTAssertNil(view.promptSelection)
    }

    func testPlainArrowCollapsesToTheSelectionEnd() {
        for _ in 0..<2 { XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift]))) }
        cliMovesCaret(by: -2)
        XCTAssertTrue(view.handlePromptSelectionKey(key(124, [])))
        XCTAssertEqual(delegate.payloads.last, right(2))
        XCTAssertNil(view.promptSelection)
    }

    func testSelectingToTheStartStopsShortUntilTheScreenConfirms() {
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift, .command])))
        // The CLI ignores presses past the start, so one is held back.
        XCTAssertEqual(delegate.payloads, [left(16)])
        cliMovesCaret(by: -16)
        XCTAssertTrue(view.handlePromptSelectionKey(key(51, [], "\u{7F}")))
        XCTAssertEqual(delegate.payloads.dropFirst(), [left(1), RelayPromptLayout.deleteBytes(extent: -17)])
    }

    func testDeleteBeforeTheCLIRedrawsFallsThrough() {
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift])))
        XCTAssertFalse(view.handlePromptSelectionKey(key(51, [], "\u{7F}")))
        XCTAssertEqual(delegate.payloads, [left(1)])
        XCTAssertNil(view.promptSelection)
    }

    func testSelectionClearsWhenThePromptChanges() {
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift])))
        cliMovesCaret(by: -1)
        spin(0.25)
        XCTAssertTrue(view.hasPromptSelection)

        view.feed(text: "\u{1B}[2;3Hj\u{1B}[2;19H")
        view.providerOutputDidArrive()
        spin(0.1)
        XCTAssertNil(view.promptSelection)
    }

    func testCLIThatDoesNotFollowTurnsSelectionOffUntilAnotherKey() {
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift])))
        spin(1.2)
        XCTAssertNil(view.promptSelection)
        XCTAssertFalse(view.handlePromptSelectionKey(key(123, [.shift])), "Falls back to editingKey")
        XCTAssertFalse(view.handlePromptSelectionKey(key(7, [], "x")))
        XCTAssertTrue(view.handlePromptSelectionKey(key(123, [.shift])))
    }

    func testWithoutAPromptShiftArrowsFallBack() {
        view.feed(text: "\u{1B}[2J\u{1B}[H$ ls")
        XCTAssertFalse(view.handlePromptSelectionKey(key(123, [.shift])))
        XCTAssertTrue(delegate.payloads.isEmpty)

        view.promptStyle = nil
        XCTAssertFalse(view.handlePromptSelectionKey(key(123, [.shift])))
    }

    func testBufferedInputFallsBack() {
        view.inputIsBuffered = { true }
        XCTAssertFalse(view.handlePromptSelectionKey(key(123, [.shift])))
        XCTAssertTrue(delegate.payloads.isEmpty)
    }

    private func cliMovesCaret(by offset: Int) {
        view.feed(text: "\u{1B}[\(abs(offset))\(offset < 0 ? "D" : "C")")
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func left(_ count: Int) -> [UInt8] {
        RelayPromptLayout.moveBytes(count: count, forward: false, applicationCursor: false)
    }

    private func right(_ count: Int) -> [UInt8] {
        RelayPromptLayout.moveBytes(count: count, forward: true, applicationCursor: false)
    }

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String? = nil) -> NSEvent {
        let arrow = keyCode == 123 || keyCode == 124
        let text = characters ?? String(UnicodeScalar(UInt16(keyCode == 123 ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey))!)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: arrow ? modifiers.union([.function, .numericPad]) : modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

private final class PromptPayloadDelegate: TerminalViewDelegate {
    private(set) var payloads: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { payloads.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
