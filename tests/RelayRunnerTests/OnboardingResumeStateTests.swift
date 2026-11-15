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

    /// RR-487: releases with a Python environment saved the voice setup step
    /// as `pythonSetup`; resuming after the upgrade lands on `voiceSetup`.
    func testLegacyPythonSetupResumeValueDecodesToVoiceSetup() {
        UserDefaults.standard.set("pythonSetup", forKey: "com.relayrunner.onboarding.resume.step")
        UserDefaults.standard.set("claude", forKey: "com.relayrunner.onboarding.resume.provider")

        XCTAssertEqual(OnboardingResumeState.load()?.step, .voiceSetup)
        XCTAssertEqual(OnboardingStepID(storedValue: "pythonSetup"), .voiceSetup)
        XCTAssertEqual(OnboardingStepID(storedValue: "voiceSetup"), .voiceSetup)
        XCTAssertNil(OnboardingStepID(rawValue: "pythonSetup"))

        OnboardingResumeState.save(step: .voiceSetup, provider: .claude, parentPermissionsReviewed: true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "com.relayrunner.onboarding.resume.step"), "voiceSetup")
    }
}
