import XCTest
@testable import relay_runner

final class AppTypographyTests: XCTestCase {
    func testAppTypographyDefinesExpectedPostScriptNames() {
        XCTAssertEqual(AppTypography.Face.ppMoriRegular.postScriptName, "PPMori-Regular")
        XCTAssertEqual(AppTypography.Face.ppMoriSemibold.postScriptName, "PPMori-SemiBold")
        XCTAssertEqual(AppTypography.Face.ppTelegrafRegular.postScriptName, "PPTelegraf-Regular")
        XCTAssertNil(AppTypography.Face.system.postScriptName)
    }

    func testAppTypographyUsesCompactCalibratedScale() {
        XCTAssertEqual(AppTypography.definition(for: .menuTab).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .appTitle).size, 22)
        XCTAssertEqual(AppTypography.definition(for: .screenTitle).size, 17)
        XCTAssertEqual(AppTypography.definition(for: .workspaceHeading).size, 14)
        XCTAssertEqual(AppTypography.definition(for: .sectionHeading).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .projectTitle).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .ticketTitle).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .field).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .metadata).size, 10)
        XCTAssertEqual(AppTypography.definition(for: .supporting).size, 10)
        XCTAssertEqual(AppTypography.definition(for: .action).size, 10)
        XCTAssertEqual(AppTypography.definition(for: .count).size, 10)
        XCTAssertEqual(AppTypography.definition(for: .caption).size, 9)
    }

    func testSemanticRolesChoosePPFaceByWeight() {
        for role in AppTypography.Role.allCases {
            let definition = AppTypography.definition(for: role)
            let expectedFace: AppTypography.Face = switch definition.fallbackWeight {
            case .regular:
                .ppTelegrafRegular
            case .medium, .semibold, .bold:
                .ppMoriSemibold
            }

            XCTAssertEqual(definition.face, expectedFace, "Unexpected face for \(role)")
        }
    }

    func testAppTypographyPrefersInstalledPPFontsForAppContent() {
        let available = Set([
            "PPMori-SemiBold",
            "PPTelegraf-Regular",
        ])

        XCTAssertEqual(
            AppTypography.resolved(.workspaceHeading, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 14, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.projectTitle, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.ticketTitle, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.metadata, availablePostScriptNames: available),
            .init(postScriptName: "PPTelegraf-Regular", size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.action, availablePostScriptNames: available),
            .init(postScriptName: "PPTelegraf-Regular", size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.menuTab, availablePostScriptNames: available),
            .init(postScriptName: "PPMori-SemiBold", size: 13, fallbackWeight: .semibold)
        )
    }

    func testAppTypographyFallsBackToSystemFontsWhenPPFontsAreUnavailable() {
        let unavailable: Set<String> = []

        XCTAssertEqual(
            AppTypography.resolved(.workspaceHeading, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 14, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.ticketTitle, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 13, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.metadata, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 10, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.caption, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: 9, fallbackWeight: .regular)
        )
    }

    func testAppKitFontUsesSameResolvedFaceAndSizeAsSwiftUIRoles() {
        let unavailable: Set<String> = []
        let expected = AppTypography.resolved(.status, availablePostScriptNames: unavailable)
        let font = AppTypography.appKitFont(.status, availablePostScriptNames: unavailable)

        XCTAssertEqual(font.pointSize, expected.size)
        XCTAssertNil(expected.postScriptName)
    }
}
