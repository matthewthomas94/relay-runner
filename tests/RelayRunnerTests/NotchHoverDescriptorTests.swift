import XCTest
@testable import relay_runner

final class NotchHoverDescriptorTests: XCTestCase {
    func testDescriptorsAreOneToThreeWordsOrNothing() {
        XCTAssertEqual(NotchHoverDescriptor.normalized("Close"), "Close")
        XCTAssertEqual(NotchHoverDescriptor.normalized("  Keep   awake "), "Keep awake")
        XCTAssertEqual(NotchHoverDescriptor.normalized("Stop and save"), "Stop and save")
        XCTAssertNil(NotchHoverDescriptor.normalized(""), "Empty copy shows nothing")
        XCTAssertNil(NotchHoverDescriptor.normalized("   "))
        XCTAssertNil(NotchHoverDescriptor.normalized("Discard the note and recording"),
                     "A sentence is dropped rather than truncated")
        XCTAssertFalse(NotchHoverDescriptor.isValid("Voice auto-play: Off — double-tap Option to play"))
    }

    func testHoverDescriptorTakesTheLabelSlotOverEveryStateLabelAndThenReleasesIt() {
        for status in [NotchSessionStatus.notWorking, .working, .listening, .playing] {
            let hovered = NotchStatusController.displayedActivityLabel(
                status: status,
                compactLabel: "Listening",
                workingProgressLabel: "Reading the ticket file",
                workingGlyphHovered: true,
                workingStatusRevealActive: true,
                workingLabelPinned: true,
                hoverDescriptor: "Keep awake"
            )
            XCTAssertEqual(hovered, "Keep awake", "\(status)")
        }
        let released = NotchStatusController.displayedActivityLabel(
            status: .listening,
            compactLabel: "Listening",
            workingProgressLabel: nil,
            workingGlyphHovered: false,
            workingStatusRevealActive: false,
            hoverDescriptor: nil
        )
        XCTAssertEqual(released, "Listening", "The state's label returns when the pointer leaves")
    }

    func testHoverDescriptorWidthStaysWithinTheRestingBudget() {
        let width = NotchStatusController.displayedActivityLabelWidth(
            status: .working,
            compactLabel: nil,
            workingProgressLabel: nil,
            workingGlyphHovered: false,
            workingStatusRevealActive: false,
            hoverDescriptor: "Add existing repository"
        )
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, NotchStatusPlacementPlanner.maximumRestingLabelWidth)
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabelWidth(
                status: .notWorking,
                compactLabel: nil,
                workingProgressLabel: nil,
                workingGlyphHovered: false,
                workingStatusRevealActive: false
            ),
            0,
            "No descriptor and no state label collapses the slot"
        )
    }

    /// Every authored hover descriptor in the app is one to three words. Only
    /// data such as a project name may be longer, and that is then not shown.
    func testEveryAuthoredHoverDescriptorIsOneToThreeWords() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        // A literal argument to `.notchHint(` or a `help:`/`helpText:` label, or a
        // literal branch of a ternary inside one. Interpolations are data and skipped.
        let pattern = #"(?:\.notchHint\(|help(?:Text)?: )(?:[^"\n]*\? )?"((?:[^"\\]|\\.)*)"(?: : "((?:[^"\\]|\\.)*)")?"#
        let regex = try NSRegularExpression(pattern: pattern)
        var checked = 0
        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                for group in 1...2 {
                    guard let groupRange = Range(match.range(at: group), in: text) else { continue }
                    let literal = String(text[groupRange])
                    // Interpolations and empty fallbacks (`?? ""`) carry data, not authored copy.
                    guard !literal.isEmpty, !literal.contains("\\(") else { continue }
                    checked += 1
                    if !NotchHoverDescriptor.isValid(literal) {
                        violations.append("\(file.lastPathComponent): \"\(literal)\"")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 30)
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
        XCTAssertTrue(files.allSatisfy { !((try? String(contentsOf: $0, encoding: .utf8))?.contains("graphicalTooltip") ?? false) },
                      "The kit tooltip is gone; hover copy lives in the notch")
    }

    /// A row's descriptor comes back when the pointer leaves a button on that
    /// row, and a toggle changing its copy keeps its depth.
    @MainActor func testLeavingAnInnerControlRestoresTheOuterDescriptor() {
        var presented: [String?] = []
        let previous = NotchHoverDescriptor.presenter
        NotchHoverDescriptor.presenter = { presented.append($0) }
        defer { NotchHoverDescriptor.presenter = previous }
        let row = UUID(), button = UUID()

        NotchHoverDescriptor.show("Show tickets", owner: row)
        NotchHoverDescriptor.show("Open in Finder", owner: button)
        NotchHoverDescriptor.show("Stop filtering", owner: row)
        NotchHoverDescriptor.hide(owner: button)
        NotchHoverDescriptor.hide(owner: button)
        NotchHoverDescriptor.hide(owner: row)

        XCTAssertEqual(presented, ["Show tickets", "Open in Finder", "Open in Finder", "Stop filtering", nil])
    }

    /// Hovering a control whose title is already on screen shows nothing: the
    /// notch adds what the control does not say, never an echo of its label.
    func testVisibleTitlesAreNotEchoedAndNoNativeTooltipRemains() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner")
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let components = try source("Settings/SettingsComponents.swift")
        XCTAssertTrue(components.contains("helpText: helpText ?? (prominence == .icon ? title : \"\")"))
        XCTAssertFalse(components.contains("helpText: helpText ?? title,"))
        let shell = try source("Board/WorkspaceOverlayShell.swift")
        XCTAssertTrue(shell.contains("self.help = help ?? \"\""))
        XCTAssertFalse(shell.contains("help: tab.title"))
        XCTAssertFalse(try source("Settings/SettingsWindow.swift").contains(".notchHint(category.title)"))
        XCTAssertFalse(try source("Onboarding/OnboardingIntroController.swift").contains(".notchHint(accessibilityLabel ?? title)"))
        let board = try source("Board/ProgramBoardOverlayView.swift")
        XCTAssertFalse(board.contains(".notchHint(item.project?.name"), "A project row says what it does, not its name")
        XCTAssertFalse(board.contains("toolTip"), "Ticket cards carry no native tooltip")
        XCTAssertFalse(board.contains("Drop here"), "Hover never fires during a drag")
        XCTAssertTrue(board.contains(".notchHint(\"Open ticket details\")"))
        for path in ["Board", "Settings", "Onboarding", "Overlay", "Terminal"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent(path), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(text.contains(".help("), "\(file.lastPathComponent) uses a native tooltip")
            }
        }
    }
}
