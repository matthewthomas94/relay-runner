import XCTest
@testable import RelayRemoteKit

final class UtteranceEndpointerTests: XCTestCase {
    private let quiet: Float = -55
    private let loud: Float = -20

    func testSilenceProducesNoEventAndTracksTheFloor() {
        var endpointer = UtteranceEndpointer()
        for i in 0..<50 {
            XCTAssertEqual(endpointer.observe(level: -40, at: Double(i) * 0.1), .none)
        }
        XCTAssertFalse(endpointer.isInSpeech)
        XCTAssertGreaterThan(endpointer.noiseFloor, -45, "the floor adapts towards the ambient level")
    }

    func testSpeechThenTrailingSilenceEndsTheUtterance() {
        var endpointer = UtteranceEndpointer()
        XCTAssertEqual(endpointer.observe(level: quiet, at: 0.0), .none)
        XCTAssertEqual(endpointer.observe(level: loud, at: 0.1), .started)
        var t = 0.2
        while t < 1.0 {
            XCTAssertEqual(endpointer.observe(level: loud, at: t), .none)
            t += 0.1
        }
        XCTAssertEqual(endpointer.observe(level: quiet, at: 1.5), .none, "0.5 s of silence is not enough")
        XCTAssertEqual(endpointer.observe(level: quiet, at: 1.95), .ended)
        XCTAssertFalse(endpointer.isInSpeech)
    }

    func testShortBlipIsDiscarded() {
        var endpointer = UtteranceEndpointer()
        XCTAssertEqual(endpointer.observe(level: loud, at: 0.0), .started)
        XCTAssertEqual(endpointer.observe(level: loud, at: 0.1), .none)
        XCTAssertEqual(endpointer.observe(level: quiet, at: 1.2), .discarded)
    }

    func testLongUtteranceIsForcedToEnd() {
        var tuning = UtteranceEndpointer.Tuning()
        tuning.maxUtterance = 5
        var endpointer = UtteranceEndpointer(tuning: tuning)
        XCTAssertEqual(endpointer.observe(level: loud, at: 0.0), .started)
        XCTAssertEqual(endpointer.observe(level: loud, at: 4.9), .none)
        XCTAssertEqual(endpointer.observe(level: loud, at: 5.0), .ended)
    }

    func testResetDropsAnUtteranceInProgress() {
        var endpointer = UtteranceEndpointer()
        XCTAssertEqual(endpointer.observe(level: loud, at: 0.0), .started)
        endpointer.reset()
        XCTAssertFalse(endpointer.isInSpeech)
        XCTAssertEqual(endpointer.observe(level: quiet, at: 2.0), .none)
    }
}
