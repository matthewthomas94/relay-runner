import XCTest
@testable import relay_runner

final class OnboardingResumeStateTests: XCTestCase {
    override func tearDown() {
        OnboardingResumeState.clear()
        super.tearDown()
    }

    func testSaveLoadAndClearResumeSnapshot() {
        OnboardingResumeState.save(
            step: .parentPermissions,
            provider: .claude,
            parentPermissionsReviewed: false
        )

        XCTAssertEqual(
            OnboardingResumeState.load(),
            OnboardingResumeState.Snapshot(
                step: .parentPermissions,
                provider: .claude,
                parentPermissionsReviewed: false
            )
        )

        OnboardingResumeState.clear()
        XCTAssertNil(OnboardingResumeState.load())
    }
}
