import XCTest
@testable import relay_runner

final class STTRecordingAccumulationTests: XCTestCase {

    func testTranscriptAccumulatorPreservesCommittedTextAcrossLiveUpdates() {
        var accumulator = TranscriptAccumulator()

        accumulator.refine("start of the long command")
        accumulator.commitLiveSegment()
        accumulator.refine("long command continues with details")

        XCTAssertEqual(
            accumulator.transcript,
            "start of the long command continues with details"
        )
    }

    func testTranscriptAccumulatorUsesLongerRefinementWithoutDuplicatingText() {
        var accumulator = TranscriptAccumulator()

        accumulator.refine("open the board")
        accumulator.commitLiveSegment()
        accumulator.refine("open the board and dispatch the ready ticket")

        XCTAssertEqual(
            accumulator.transcript,
            "open the board and dispatch the ready ticket"
        )
    }

    func testTranscriptAccumulatorResetClearsPartialAndCommittedText() {
        var accumulator = TranscriptAccumulator()

        accumulator.refine("do not send this")
        accumulator.commitLiveSegment()
        accumulator.refine("partial tail")
        accumulator.reset()

        XCTAssertFalse(accumulator.hasTranscript)
        XCTAssertEqual(accumulator.transcript, "")
    }

    func testAudioBufferCanDisableRolloverDuringRecording() {
        let buffer = AudioBuffer()
        let samples = (0..<(AudioBuffer.defaultMaxSamples + 10)).map { Float($0) }

        buffer.setMaxSamples(nil)
        buffer.append(samples)

        XCTAssertEqual(buffer.get().count, AudioBuffer.defaultMaxSamples + 10)

        buffer.setMaxSamples(AudioBuffer.defaultMaxSamples)

        XCTAssertEqual(buffer.get().count, AudioBuffer.defaultMaxSamples)
    }

    func testAudioBufferDiscardPrefixPreservesOverlapAndNewSamples() {
        let buffer = AudioBuffer()
        buffer.setMaxSamples(nil)
        buffer.append((1...6).map { Float($0) })
        let transcribedSampleCount = buffer.get().count

        buffer.append((7...10).map { Float($0) })
        buffer.discardPrefix(upTo: transcribedSampleCount, keeping: 2)

        XCTAssertEqual(buffer.get(), [5, 6, 7, 8, 9, 10].map { Float($0) })
    }

    func testTutorialVoiceOutputNeverPublishesToTheVoiceFIFO() {
        var published: [String] = []

        let tutorialResult = STTEngine.writeVoiceOutput(
            "private tutorial transcript",
            tutorialActive: true,
            writer: {
                published.append($0)
                return true
            }
        )
        let ordinaryResult = STTEngine.writeVoiceOutput(
            "ordinary command",
            tutorialActive: false,
            writer: {
                published.append($0)
                return true
            }
        )

        XCTAssertFalse(tutorialResult)
        XCTAssertTrue(ordinaryResult)
        XCTAssertEqual(published, ["ordinary command"])
    }

    func testPlaybackControlsCarryDetectionAndVisualAcknowledgementTiming() {
        let detected = Date(timeIntervalSince1970: 1_000.125)
        let acknowledged = Date(timeIntervalSince1970: 1_000.175)

        XCTAssertEqual(
            STTEngine.playControl(detectedAt: detected),
            "__PLAY__:1000.125000"
        )
        XCTAssertEqual(
            STTEngine.playAcknowledgementControl(
                detectedAt: detected,
                acknowledgedAt: acknowledged
            ),
            "__PLAY_ACK__:1000.125000:1000.175000"
        )
    }
}
