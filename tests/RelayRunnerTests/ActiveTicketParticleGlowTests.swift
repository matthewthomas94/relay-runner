import AppKit
import XCTest
@testable import relay_runner

@MainActor
final class ActiveTicketParticleGlowTests: XCTestCase {
    func testPresentationUsesAuthoritativeActiveWorkerState() {
        let active = item(status: "in_progress", runState: "active")
        let laneOnly = item(status: "in_progress", runState: nil)
        let awaitingReview = item(status: "in_progress", runState: "awaiting_merge")
        let failed = item(status: "in_progress", runState: "failed")

        XCTAssertEqual(
            ProgramActiveTicketGlowPresentation.resolve(item: active, reduceMotion: false),
            ProgramActiveTicketGlowPresentation(isVisible: true, animatesMask: true)
        )
        XCTAssertEqual(
            ProgramActiveTicketGlowPresentation.resolve(item: active, reduceMotion: true),
            ProgramActiveTicketGlowPresentation(isVisible: true, animatesMask: false)
        )
        XCTAssertFalse(ProgramActiveTicketGlowPresentation.resolve(item: laneOnly, reduceMotion: false).isVisible)
        XCTAssertFalse(ProgramActiveTicketGlowPresentation.resolve(item: awaitingReview, reduceMotion: false).isVisible)
        XCTAssertFalse(ProgramActiveTicketGlowPresentation.resolve(item: failed, reduceMotion: false).isVisible)
    }

    func testGlowViewUsesOneSharedClockForRendererAndMask() {
        let clock = ParticleFieldAnimationClock(interval: 1.0 / 120)
        let view = ActiveTicketParticleGlowView(animationClock: clock)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        view.layout()

        XCTAssertEqual(clock.activeCallbackCount, 0)

        view.setVisible(true, animatesMask: true)
        XCTAssertEqual(clock.activeCallbackCount, 2)

        clock.tickForTesting()
        view.setVisible(true, animatesMask: false)
        XCTAssertEqual(clock.activeCallbackCount, 1)

        view.setVisible(false, animatesMask: false)
        XCTAssertEqual(clock.activeCallbackCount, 0)
    }

    func testMultipleActiveCardsKeepIndependentCallbacksOnSharedClock() {
        let clock = ParticleFieldAnimationClock(interval: 1.0 / 120)
        let first = ActiveTicketParticleGlowView(animationClock: clock)
        let second = ActiveTicketParticleGlowView(animationClock: clock)
        first.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        second.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        first.layout()
        second.layout()

        first.setVisible(true, animatesMask: true)
        second.setVisible(true, animatesMask: true)
        XCTAssertEqual(clock.activeCallbackCount, 4)

        first.setVisible(false, animatesMask: false)
        XCTAssertEqual(clock.activeCallbackCount, 2)

        second.setVisible(false, animatesMask: false)
        XCTAssertEqual(clock.activeCallbackCount, 0)
    }

    func testMetaballMaskEvolvesAndStaysLocalToEffectBounds() {
        let cardSize = CGSize(width: 280, height: 92)
        let effectSize = ActiveTicketGlowMaskGeometry.effectSize(forCardSize: cardSize)
        let bounds = CGRect(origin: .zero, size: effectSize)

        let start = ActiveTicketGlowMaskGeometry.boundingBox(in: bounds, elapsed: 0)
        let later = ActiveTicketGlowMaskGeometry.boundingBox(in: bounds, elapsed: 2.35)

        XCTAssertNotEqual(start.origin.x, later.origin.x, accuracy: 0.25)
        XCTAssertNotEqual(start.size.width, later.size.width, accuracy: 0.25)
        XCTAssertTrue(bounds.contains(start))
        XCTAssertTrue(bounds.contains(later))
        XCTAssertGreaterThan(start.width, cardSize.width)
        XCTAssertGreaterThan(start.height, cardSize.height)
    }

    func testEffectSizeExtendsPastCardWithoutChangingCardLayoutSize() {
        let cardSize = CGSize(width: 280, height: 92)
        let effectSize = ActiveTicketGlowMaskGeometry.effectSize(forCardSize: cardSize)

        XCTAssertEqual(effectSize.width, cardSize.width + ActiveTicketGlowMaskGeometry.horizontalOutset * 2)
        XCTAssertEqual(effectSize.height, cardSize.height + ActiveTicketGlowMaskGeometry.verticalOutset * 2)
    }

    private func item(status: String, runState: String?) -> ProgramStatusItem {
        ProgramStatusItem(
            project: ProgramStatusProject(name: "Relay Runner", path: "/repo/relay-runner"),
            ticketID: "RR-213",
            title: "Active card glow",
            status: status,
            priority: "high",
            runID: runState == nil ? nil : "314",
            runState: runState,
            provider: "Codex/gpt-5"
        )
    }
}
