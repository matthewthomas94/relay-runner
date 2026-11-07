import XCTest
@testable import relay_runner

final class AppTypographyTests: XCTestCase {
    func testAppTypographyDefinesExpectedPostScriptNames() {
        XCTAssertEqual(AppTypography.Face.baiJamjureeRegular.postScriptName, "BaiJamjuree-Regular")
        XCTAssertEqual(AppTypography.Face.baiJamjureeSemibold.postScriptName, "BaiJamjuree-SemiBold")
        XCTAssertNil(AppTypography.Face.system.postScriptName)
    }

    func testBundledBaiJamjureeResolvesWithoutAUserInstall() {
        XCTAssertEqual(AppTypography.appKitFont(.ticketTitle).fontName, "BaiJamjuree-SemiBold")
        XCTAssertEqual(AppTypography.appKitFont(.body).fontName, "BaiJamjuree-Regular")
    }

    func testAppTypographyFollowsTheGraphicalTypeScale() {
        let scale: Set<CGFloat> = [8, 12, 16, 20, 24, 32, 40]
        let overlayRoles: [AppTypography.Role] = [.pillTitle, .pillBody, .notchStatus]
        for role in AppTypography.Role.allCases where !overlayRoles.contains(role) {
            XCTAssertTrue(scale.contains(AppTypography.definition(for: role).size), "\(role) is off the kit scale")
        }
        XCTAssertEqual(AppTypography.definition(for: .body).size, GraphicalTheme.textS)
        XCTAssertEqual(AppTypography.definition(for: .button).size, GraphicalTheme.textS)
        XCTAssertEqual(AppTypography.definition(for: .caption).size, GraphicalTheme.textXS)
        XCTAssertEqual(AppTypography.definition(for: .screenTitle).size, GraphicalTheme.textM)
        XCTAssertEqual(AppTypography.definition(for: .onboardingHero).size, GraphicalTheme.textXL)
        XCTAssertEqual(
            AppTypography.definition(for: .programProjectsHeading).size,
            AppTypography.definition(for: .sectionHeading).size
        )
        // The listening and speaking pills and the notch keep their own sizes.
        XCTAssertEqual(AppTypography.definition(for: .pillTitle).size, 13)
        XCTAssertEqual(AppTypography.definition(for: .pillBody).size, 14)
        XCTAssertEqual(AppTypography.definition(for: .notchStatus).size, 12)
    }

    func testSemanticRolesChooseBaiJamjureeFaceByWeight() {
        for role in AppTypography.Role.allCases {
            let definition = AppTypography.definition(for: role)
            let expectedFace: AppTypography.Face = switch definition.fallbackWeight {
            case .regular:
                .baiJamjureeRegular
            case .medium, .semibold, .bold:
                .baiJamjureeSemibold
            }

            XCTAssertEqual(definition.face, expectedFace, "Unexpected face for \(role)")
        }
    }

    func testAppTypographyPrefersBaiJamjureeForAppContent() {
        let available = Set([
            "BaiJamjuree-SemiBold",
            "BaiJamjuree-Regular",
        ])

        XCTAssertEqual(
            AppTypography.resolved(.workspaceHeading, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .workspaceHeading).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.projectTitle, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .projectTitle).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.ticketTitle, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .ticketTitle).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.primaryButton, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .primaryButton).size, fallbackWeight: .semibold),
            "Primary buttons label in semibold"
        )
        XCTAssertEqual(
            AppTypography.resolved(.metadata, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .metadata).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.action, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .action).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.programAction, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .programAction).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.menuTab, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .menuTab).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.pillTitle, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .pillTitle).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.pillBody, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .pillBody).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.onboardingHero, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .onboardingHero).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.permissionButton, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-Regular", size: AppTypography.definition(for: .permissionButton).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.notchStatus, availablePostScriptNames: available),
            .init(postScriptName: "BaiJamjuree-SemiBold", size: AppTypography.definition(for: .notchStatus).size, fallbackWeight: .semibold)
        )
    }

    func testAppTypographyFallsBackToSystemFontsWhenBaiJamjureeIsUnavailable() {
        let unavailable: Set<String> = []

        XCTAssertEqual(
            AppTypography.resolved(.workspaceHeading, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: AppTypography.definition(for: .workspaceHeading).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.ticketTitle, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: AppTypography.definition(for: .ticketTitle).size, fallbackWeight: .semibold)
        )
        XCTAssertEqual(
            AppTypography.resolved(.metadata, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: AppTypography.definition(for: .metadata).size, fallbackWeight: .regular)
        )
        XCTAssertEqual(
            AppTypography.resolved(.caption, availablePostScriptNames: unavailable),
            .init(postScriptName: nil, size: AppTypography.definition(for: .caption).size, fallbackWeight: .regular)
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
