import XCTest
@testable import relay_runner

final class OnboardingIntroTests: XCTestCase {
    func testIntroEligibilityIsFreshAutomaticOnly() {
        XCTAssertTrue(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: true,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: true,
            reduceMotion: false
        ))
    }

    func testReduceMotionBypassesIntro() {
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: true
        ))
    }

    func testRevealCompletionStartsTimelineOnlyWhenSurfaceIsStillActive() {
        XCTAssertEqual(
            OnboardingIntroPolicy.completionPlan(
                revealCompleted: true,
                skipRequested: false,
                timelineComplete: false,
                isCompleting: false
            ),
            OnboardingIntroCompletionPlan(
                startsTimeline: true,
                cleansUpSurface: false,
                performsHandoff: false
            )
        )
        XCTAssertFalse(OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: false,
            isCompleting: true
        ).startsTimeline)
    }

    func testSkipAndTimelineCompletionUseSameCleanupAndHandoffPlan() {
        let skip = OnboardingIntroPolicy.completionPlan(
            revealCompleted: false,
            skipRequested: true,
            timelineComplete: false,
            isCompleting: false
        )
        let complete = OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: true,
            isCompleting: false
        )

        XCTAssertEqual(skip.cleansUpSurface, true)
        XCTAssertEqual(skip.performsHandoff, true)
        XCTAssertEqual(complete, skip)
    }

    func testTimelineTypesHoldsAndErasesFirstPhrase() {
        let first = OnboardingIntroTimeline.phrases[0]
        let firstCount = Double(Array(first).count)

        XCTAssertEqual(OnboardingIntroTimeline.frame(at: 0).text, "/")
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.typingInterval).text,
            "F /"
        )

        let full = OnboardingIntroTimeline.frame(at: firstCount * OnboardingIntroTimeline.typingInterval)
        XCTAssertEqual(full.activePhrase, first)
        XCTAssertEqual(full.text, "\(first) /")

        let holding = OnboardingIntroTimeline.frame(
            at: firstCount * OnboardingIntroTimeline.typingInterval
                + OnboardingIntroTimeline.phraseHold / 2
        )
        XCTAssertEqual(holding.text, "\(first) /")

        let erased = OnboardingIntroTimeline.frame(
            at: firstCount * OnboardingIntroTimeline.typingInterval
                + OnboardingIntroTimeline.phraseHold
                + firstCount * OnboardingIntroTimeline.eraseInterval
                - 0.001
        )
        XCTAssertEqual(erased.text, "/")
        XCTAssertFalse(erased.isComplete)
    }

    func testTimelineCompletesBackAtCursor() {
        let complete = OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.duration)

        XCTAssertEqual(complete.activePhrase, "Relay Runner")
        XCTAssertEqual(complete.text, "/")
        XCTAssertTrue(complete.isComplete)
    }

    func testFreshInteractiveHandoffCanStartAtAgentChoice() {
        let step = OnboardingView.initialStep(
            simplified: false,
            resumeStep: nil,
            requiresAgentChoice: true,
            requiresParentPermissionGuidance: false,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            fullFlowInitialStep: .agentChoice
        )

        XCTAssertEqual(step, .agentChoice)
    }
}
