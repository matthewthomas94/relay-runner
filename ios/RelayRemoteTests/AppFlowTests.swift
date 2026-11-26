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

final class SplashTimelineTests: XCTestCase {
    func testBeatsFollowTheDesktopSchedule() {
        typealias T = SplashTimeline
        XCTAssertEqual(T.frame(at: 0).visible, 1)
        XCTAssertEqual(T.frame(at: 0.69).visible, 1, "R holds for 0.7 s")
        XCTAssertEqual(T.frame(at: 0.7 + 0.03).visible, 2, "one character every 0.029 s")
        XCTAssertEqual(T.frame(at: T.glowStart).visible, 12)
        XCTAssertEqual(T.frame(at: T.glowStart).glow, 0, accuracy: 0.001)
        XCTAssertEqual(T.frame(at: T.glowStart + 2).glow, 0.5, accuracy: 0.001, "smoothstep midpoint")
        XCTAssertEqual(T.frame(at: T.glowStart + 4).glow, 1, accuracy: 0.001)
        XCTAssertEqual(T.frame(at: T.firstSwapStart - 0.01).phrase, 0)
        let first = T.frame(at: T.firstSwapStart + 0.24 + 0.24 + 0.5)
        XCTAssertEqual(first.phrase, 1)
        XCTAssertEqual(first.hidden, 0, accuracy: 0.001)
        XCTAssertEqual(first.glowOpacity, 0)
        XCTAssertEqual(T.secondSwapStart - T.firstSwapStart, 0.24 * 2 + 1.05, accuracy: 0.001)
        XCTAssertEqual(T.frame(at: T.secondSwapStart + 0.48 + 0.5).phrase, 2)
        XCTAssertFalse(T.frame(at: T.duration - 0.01).isComplete)
        XCTAssertEqual(T.duration - T.secondSwapStart, 0.48 + 1.4, accuracy: 0.001)
        XCTAssertTrue(T.frame(at: T.duration).isComplete)
    }
}
