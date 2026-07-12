import XCTest
@testable import relay_runner

final class WorkspaceTypographyTests: XCTestCase {
    func testWorkspaceTypographyDefinesExpectedPostScriptNames() {
        XCTAssertEqual(WorkspaceTypography.Face.ppMoriRegular.postScriptName, "PPMori-Regular")
        XCTAssertEqual(WorkspaceTypography.Face.ppMoriSemibold.postScriptName, "PPMori-SemiBold")
        XCTAssertEqual(WorkspaceTypography.Face.ppTelegrafRegular.postScriptName, "PPTelegraf-Regular")
        XCTAssertNil(WorkspaceTypography.Face.system.postScriptName)
    }

    func testWorkspaceTypographyUsesCompactCalibratedScale() {
        XCTAssertEqual(WorkspaceTypography.definition(for: .menuTab).size, 13)
        XCTAssertEqual(WorkspaceTypography.definition(for: .workspaceHeading).size, 14)
        XCTAssertEqual(WorkspaceTypography.definition(for: .sectionHeading).size, 13)
        XCTAssertEqual(WorkspaceTypography.definition(for: .projectTitle).size, 13)
        XCTAssertEqual(WorkspaceTypography.definition(for: .ticketTitle).size, 13)
        XCTAssertEqual(WorkspaceTypography.definition(for: .metadata).size, 10)
        XCTAssertEqual(WorkspaceTypography.definition(for: .supporting).size, 10)
        XCTAssertEqual(WorkspaceTypography.definition(for: .action).size, 10)
        XCTAssertEqual(WorkspaceTypography.definition(for: .count).size, 10)
        XCTAssertEqual(WorkspaceTypography.definition(for: .caption).size, 9)
    }

    func testWorkspaceTypographyPrefersInstalledPPFontsForBoardContent() {
        let available = Set([
            "PPMori-SemiBold",
            "PPTelegraf-Regular",
        ])

        XCTAssertEqual(
            WorkspaceTypography.resolved(.workspaceHeading, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 14, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.projectTitle, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.ticketTitle, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.metadata, availablePostScriptNames: available),
            .init(postScriptName: "PPTelegraf-Regular", size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.action, availablePostScriptNames: available),
            .init(postScriptName: "PPTelegraf-Regular", size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.menuTab, availablePostScriptNames: available),
            .init(postScriptName: nil, size: 13, fallbackWeight: .semibold)
        )
    }

    func testWorkspaceTypographyFallsBackToSystemFontsWhenPPFontsAreUnavailable() {
        let unavailable: Set<String> = []

        XCTAssertEqual(
            WorkspaceTypography.resolved(.workspaceHeading, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 14, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.ticketTitle, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.metadata, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            WorkspaceTypography.resolved(.caption, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 9, fallbackWeight: .regular)
        )
    }
}
