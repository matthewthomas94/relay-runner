import XCTest
@testable import RelayRemote

final class AppFlowTests: XCTestCase {
    func testFirstLaunchWalksEveryStage() {
        var stage = AppFlow.initialStage(onboardingFinished: false, paired: false)
        var walked = [stage]
        while stage != .app {
            stage = AppFlow.stage(after: stage, onboardingFinished: false)
            walked.append(stage)
        }
        XCTAssertEqual(walked, [.splash, .permissions, .pairing, .tutorial, .app])
    }

    func testLaterLaunchesOpenTheAppWhenPairedAndPairingWhenNot() {
        XCTAssertEqual(AppFlow.initialStage(onboardingFinished: true, paired: true), .app)
        XCTAssertEqual(AppFlow.initialStage(onboardingFinished: true, paired: false), .pairing)
        XCTAssertEqual(AppFlow.stage(after: .pairing, onboardingFinished: true), .app,
                       "pairing again skips the tutorial")
        XCTAssertEqual(AppFlow.initialStage(onboardingFinished: false, paired: true), .splash,
                       "an unfinished onboarding starts over")
    }

    func testOnboardingProgressPersists() throws {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(OnboardingProgress(defaults: defaults).isFinished)
        OnboardingProgress(defaults: defaults).isFinished = true
        XCTAssertTrue(OnboardingProgress(defaults: defaults).isFinished)
    }

    func testLaunchOptions() {
        let options = LaunchOptions(arguments: ["RelayRemote", "--stage=tutorial", "--tab=settings",
                                                "--reset-onboarding"])
        XCTAssertEqual(options.stage, .tutorial)
        XCTAssertEqual(options.tab, .settings)
        XCTAssertTrue(options.resetsOnboarding)
        XCTAssertFalse(options.showsGallery)
        let gallery = LaunchOptions(arguments: ["--gallery=orbs"])
        XCTAssertTrue(gallery.showsGallery)
        XCTAssertEqual(gallery.galleryPage, "orbs")
        XCTAssertTrue(LaunchOptions(arguments: ["--gallery"]).showsGallery)
        XCTAssertEqual(LaunchOptions(arguments: ["-stage", "app"]), LaunchOptions(arguments: []))
    }

    func testTalkModeDefaultsToHoldAndPersists() throws {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TalkModePreference(defaults: defaults).mode, .hold)
        TalkModePreference(defaults: defaults).mode = .toggle
        XCTAssertEqual(TalkModePreference(defaults: defaults).mode, .toggle)
        defaults.set("handsFree", forKey: TalkModePreference.key)
        XCTAssertEqual(TalkModePreference(defaults: defaults).mode, .hold)
    }

    func testReplyNotificationsDefaultOnAndPersist() throws {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ReplyNotificationsPreference(defaults: defaults).isOn)
        ReplyNotificationsPreference(defaults: defaults).isOn = false
        XCTAssertFalse(ReplyNotificationsPreference(defaults: defaults).isOn)
    }
}
