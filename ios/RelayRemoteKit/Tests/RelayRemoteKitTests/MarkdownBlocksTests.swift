import Foundation
import XCTest
@testable import RelayRemoteKit

/// RR-551: the Markdown the ticket modal draws.
final class MarkdownBlocksTests: XCTestCase {
    private let sample = """
    ## Description

    Open a ticket from the **phone**, in *italics*, with `inline code` and a [link](https://example.com/x).
    A wrapped second line.

    ### Acceptance criteria

    - first bullet
    - second bullet
      with a wrapped line

    1. numbered one
    2. numbered two

    - [ ] open task
    - [x] done task

    ```swift
    let wide = "a very long line that must scroll sideways rather than wrap"
      indented
    ```

    Last paragraph.
    """

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    func testEachElementBecomesItsBlock() throws {
        let blocks = MarkdownBlocks.parse(sample)
        guard case .heading(let level, let title) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(plain(title), "Description")
        guard case .paragraph(let paragraph) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(plain(paragraph),
                       "Open a ticket from the phone, in italics, with inline code and a link. A wrapped second line.")
        guard case .heading(3, _) = blocks[2] else { return XCTFail("\(blocks[2])") }
        guard case .list(let bullets) = blocks[3] else { return XCTFail("\(blocks[3])") }
        XCTAssertEqual(bullets.map { plain($0.text) }, ["first bullet", "second bullet with a wrapped line"])
        XCTAssertEqual(bullets.map(\.marker), [.bullet, .bullet])
        guard case .list(let numbers) = blocks[4] else { return XCTFail("\(blocks[4])") }
        XCTAssertEqual(numbers.map(\.marker), [.number(1), .number(2)])
        guard case .list(let tasks) = blocks[5] else { return XCTFail("\(blocks[5])") }
        XCTAssertEqual(tasks.map(\.marker), [.task(checked: false), .task(checked: true)])
        XCTAssertEqual(tasks.map { plain($0.text) }, ["open task", "done task"])
        guard case .code(let code) = blocks[6] else { return XCTFail("\(blocks[6])") }
        XCTAssertEqual(code, "let wide = \"a very long line that must scroll sideways rather than wrap\"\n  indented")
        guard case .paragraph(let last) = blocks[7] else { return XCTFail("\(blocks[7])") }
        XCTAssertEqual(plain(last), "Last paragraph.")
        XCTAssertEqual(blocks.count, 8)
    }

    func testInlineStylesAndLinksSurvive() throws {
        guard case .paragraph(let text) = MarkdownBlocks.parse(sample)[1] else { return XCTFail() }
        var intents: [String: InlinePresentationIntent] = [:]
        var links: [URL] = []
        for run in text.runs {
            if let intent = run.inlinePresentationIntent { intents[String(text[run.range].characters)] = intent }
            if let link = run.link { links.append(link) }
        }
        XCTAssertEqual(intents["phone"], .stronglyEmphasized)
        XCTAssertEqual(intents["italics"], .emphasized)
        XCTAssertEqual(intents["inline code"], .code)
        XCTAssertEqual(links, [URL(string: "https://example.com/x")!])
    }

    func testNestedListsKeepTheirDepth() {
        let blocks = MarkdownBlocks.parse("- one\n  - nested\n- two")
        guard case .list(let items) = blocks.first else { return XCTFail() }
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
    }

    func testAnUnclosedFenceRunsToTheEndAndABlankLineKeepsOneList() {
        XCTAssertEqual(MarkdownBlocks.parse("```\nline one\nline two"), [.code("line one\nline two")])
        let loose = MarkdownBlocks.parse("- a\n\n- b")
        XCTAssertEqual(loose.count, 1)
        guard case .list(let items) = loose.first else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
    }

    func testHeadingsNeedASpaceAndLoseTheirClosingHashes() {
        guard case .paragraph = MarkdownBlocks.parse("#hashtag")[0] else { return XCTFail("#hashtag is text") }
        guard case .heading(1, let title) = MarkdownBlocks.parse("# Title ##")[0] else { return XCTFail() }
        XCTAssertEqual(plain(title), "Title")
    }

    func testEmptyAndPlainText() {
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("\n\n  \n"), [])
        guard case .paragraph(let text) = MarkdownBlocks.parse("just words")[0] else { return XCTFail() }
        XCTAssertEqual(plain(text), "just words")
    }
}
