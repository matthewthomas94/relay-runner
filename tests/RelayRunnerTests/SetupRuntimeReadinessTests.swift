import XCTest
@testable import relay_runner

final class SetupRuntimeReadinessTests: XCTestCase {

    func testCompilingStateTimesOutToRetryableFailure() {
        let startedAt = Date(timeIntervalSince1970: 100)

        let readiness = SetupRuntimeReadiness.resolve(
            engineStatusMessage: "Compiling parakeet-tdt-v2...",
            engineError: nil,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(61),
            timeout: 60
        )

        XCTAssertEqual(
            readiness,
            .failed("Speech-to-Text setup timed out while compiling parakeet-tdt-v2. Retry setup to restart model loading.")
        )
        XCTAssertTrue(readiness.canRetry)
        XCTAssertFalse(readiness.isReady)
    }

    func testListeningConvergesToLoadedAndListeningEvenAfterTimeoutWindow() {
        let startedAt = Date(timeIntervalSince1970: 100)

        let readiness = SetupRuntimeReadiness.resolve(
            engineStatusMessage: "Listening",
            engineError: nil,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(120),
            timeout: 60
        )

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(readiness.statusDetail, "Loaded and listening")
        XCTAssertFalse(readiness.canRetry)
    }

    func testStartupErrorBecomesExplicitRetryableFailure() {
        let readiness = SetupRuntimeReadiness.resolve(
            engineStatusMessage: "Loading STT model...",
            engineError: "failed to download model from HuggingFace",
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 101),
            timeout: 60
        )

        XCTAssertEqual(readiness, .failed("Couldn't download the speech recognition model."))
        XCTAssertTrue(readiness.canRetry)
    }

    func testStartedWithoutMessageStaysFinitePreparingBeforeTimeout() {
        let startedAt = Date(timeIntervalSince1970: 100)

        let readiness = SetupRuntimeReadiness.resolve(
            engineStatusMessage: "",
            engineError: nil,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(10),
            timeout: 60
        )

        XCTAssertEqual(readiness, .preparing("Starting speech-to-text model..."))
        XCTAssertFalse(readiness.canRetry)
    }
}
