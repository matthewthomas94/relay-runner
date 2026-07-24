import XCTest
@testable import relay_runner

final class OnboardingSessionControlsTutorialAnimationTests: XCTestCase {
    func testCapsLockUsesVectorAssetVariantsForLightState() {
        XCTAssertEqual(
            OnboardingTutorialKeycapKind.capsLock.assetName(capsLightOn: true),
            "OnboardingTutorialCapsLockKey"
        )
        XCTAssertEqual(
            OnboardingTutorialKeycapKind.capsLock.assetName(capsLightOn: false),
            "OnboardingTutorialCapsLockKeyOff"
        )
        XCTAssertEqual(
            OnboardingTutorialKeycapKind.option.assetName(),
            "OnboardingTutorialOptionKey"
        )
    }

    func testCapsLockAnimationUsesLongerCadenceAndTogglesLightAfterPress() {
        XCTAssertGreaterThan(OnboardingTutorialKeycapAnimation.capsLock.cycleDuration, 1.0)

        let initial = OnboardingSessionControlsTutorial.keycapPhase(for: .capsLock, at: 0)
        let pressed = OnboardingSessionControlsTutorial.keycapPhase(for: .capsLock, at: 0.14)
        let resting = OnboardingSessionControlsTutorial.keycapPhase(for: .capsLock, at: 0.9)

        XCTAssertEqual(initial.scale, 1, accuracy: 0.0001)
        XCTAssertFalse(initial.capsLightOn)
        XCTAssertLessThan(pressed.scale, 1)
        XCTAssertTrue(pressed.capsLightOn)
        XCTAssertEqual(resting.scale, 1, accuracy: 0.0001)
        XCTAssertTrue(resting.capsLightOn)
    }

    func testCapsLockScaleRemainsContinuousAcrossPressBoundaries() {
        let epsilon = 0.0005
        let beforePressBottom = OnboardingSessionControlsTutorial.keycapPhase(
            for: .capsLock,
            at: 0.14 - epsilon
        )
        let afterPressBottom = OnboardingSessionControlsTutorial.keycapPhase(
            for: .capsLock,
            at: 0.14 + epsilon
        )
        let beforeReleaseEnd = OnboardingSessionControlsTutorial.keycapPhase(
            for: .capsLock,
            at: 0.32 - epsilon
        )
        let afterReleaseEnd = OnboardingSessionControlsTutorial.keycapPhase(
            for: .capsLock,
            at: 0.32 + epsilon
        )

        XCTAssertLessThan(abs(beforePressBottom.scale - afterPressBottom.scale), 0.002)
        XCTAssertLessThan(abs(beforeReleaseEnd.scale - afterReleaseEnd.scale), 0.002)
    }

    func testPlaybackOptionAndControlAlternateInsteadOfAnimatingTogether() {
        XCTAssertGreaterThan(OnboardingTutorialKeycapAnimation.playbackOption.cycleDuration, 1.15)

        let optionGesture = OnboardingSessionControlsTutorial.keycapPhase(for: .playbackOption, at: 0.14)
        let controlWhileOptionRuns = OnboardingSessionControlsTutorial.keycapPhase(for: .playbackControl, at: 0.14)
        let pauseBetweenGestures = OnboardingSessionControlsTutorial.keycapPhase(for: .playbackOption, at: 0.95)
        let controlGesture = OnboardingSessionControlsTutorial.keycapPhase(for: .playbackControl, at: 1.44)
        let optionWhileControlRuns = OnboardingSessionControlsTutorial.keycapPhase(for: .playbackOption, at: 1.44)

        XCTAssertLessThan(optionGesture.scale, 1)
        XCTAssertEqual(controlWhileOptionRuns.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(pauseBetweenGestures.scale, 1, accuracy: 0.0001)
        XCTAssertLessThan(controlGesture.scale, 1)
        XCTAssertEqual(optionWhileControlRuns.scale, 1, accuracy: 0.0001)
    }

    func testShiftDoubleTapUsesLongerRepeatIntervalAndStablePause() {
        XCTAssertGreaterThan(OnboardingTutorialKeycapAnimation.shift.cycleDuration, 1.15)

        let firstTap = OnboardingSessionControlsTutorial.keycapPhase(for: .shift, at: 0.1)
        let secondTap = OnboardingSessionControlsTutorial.keycapPhase(for: .shift, at: 0.32)
        let resting = OnboardingSessionControlsTutorial.keycapPhase(for: .shift, at: 0.9)

        XCTAssertLessThan(firstTap.scale, 1)
        XCTAssertLessThan(secondTap.scale, 1)
        XCTAssertEqual(resting.scale, 1, accuracy: 0.0001)
    }

    func testTutorialCursorUsesSmoothPulseAndReduceMotionFallback() {
        XCTAssertEqual(OnboardingSessionControlsTutorial.tutorialCursorOpacity(at: 0), 1, accuracy: 0.0001)

        let mid = OnboardingSessionControlsTutorial.tutorialCursorOpacity(
            at: OnboardingIntroTimeline.cursorBlinkPeriod / 2
        )
        let nearMid = OnboardingSessionControlsTutorial.tutorialCursorOpacity(
            at: OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
        )

        XCTAssertEqual(mid, OnboardingCursorBlink.minimumOpacity, accuracy: 0.0001)
        XCTAssertGreaterThan(nearMid, OnboardingCursorBlink.minimumOpacity)
        XCTAssertLessThan(nearMid, 0.52)
        XCTAssertEqual(
            OnboardingSessionControlsTutorial.tutorialCursorOpacity(at: 0.2, reduceMotion: true),
            0.82,
            accuracy: 0.0001
        )
    }

    func testReduceMotionKeepsKeycapsStaticAndEmphasized() {
        let caps = OnboardingSessionControlsTutorial.keycapPhase(
            for: .capsLock,
            at: 1.2,
            reduceMotion: true
        )
        let option = OnboardingSessionControlsTutorial.keycapPhase(
            for: .playbackOption,
            at: 1.2,
            reduceMotion: true
        )

        XCTAssertEqual(caps.scale, 0.97, accuracy: 0.0001)
        XCTAssertTrue(caps.capsLightOn)
        XCTAssertEqual(option.scale, 0.97, accuracy: 0.0001)
        XCTAssertFalse(option.capsLightOn)
    }
}
