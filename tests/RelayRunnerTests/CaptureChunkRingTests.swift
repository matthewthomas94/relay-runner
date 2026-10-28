import AVFAudio
import CoreAudio
import XCTest
@testable import relay_runner

/// The ring is the real-time handoff of the input-only capture backend, so it
/// runs here without a microphone: the test thread plays the HAL IO thread.
final class CaptureChunkRingTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    func testDeliversFixedChunksInOrderAcrossUnevenIOCycles() {
        let ring = CaptureChunkRing(format: format, chunkFrames: 8)!
        let lock = NSLock()
        var chunks: [[Float]] = []
        let delivered = expectation(description: "three chunks")
        delivered.expectedFulfillmentCount = 3
        ring.start { buffer in
            let left = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)
            ))
            let right = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![1],
                count: Int(buffer.frameLength)
            ))
            XCTAssertEqual(right, left.map { -$0 })
            lock.lock()
            chunks.append(left)
            lock.unlock()
            delivered.fulfill()
        }

        var next = 0
        for count in [3, 5, 7, 1, 2, 6, 4] {
            write(ring, from: next, count: count)
            next += count
        }
        wait(for: [delivered], timeout: 5)
        ring.stop()

        // 28 frames: three whole chunks, and the trailing partial is never delivered.
        XCTAssertEqual(chunks, [0..<8, 8..<16, 16..<24].map { $0.map(Float.init) })
    }

    func testCyclesBeyondAFullRingAreDroppedUntilDeliveryCatchesUp() {
        let ring = CaptureChunkRing(format: format, chunkFrames: 4, slotCount: 2)!
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var firstFrames: [Float] = []
        ring.start { buffer in
            lock.lock()
            firstFrames.append(buffer.floatChannelData![0][0])
            lock.unlock()
            entered.signal()
            release.wait()
        }

        write(ring, from: 0, count: 4)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        write(ring, from: 4, count: 4)
        write(ring, from: 8, count: 4) // both slots taken: dropped
        release.signal()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        write(ring, from: 12, count: 4) // the first slot is free again
        release.signal()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        release.signal()
        ring.stop()

        XCTAssertEqual(firstFrames, [0, 4, 12])
    }

    func testStopJoinsTheDeliveryThreadAndDropsAPartialChunk() {
        let ring = CaptureChunkRing(format: format, chunkFrames: 8)!
        var deliveries = 0
        ring.start { _ in deliveries += 1 }

        write(ring, from: 0, count: 5)
        ring.stop()
        ring.stop()

        XCTAssertEqual(deliveries, 0)
    }

    func testRejectsInterleavedInput() {
        let interleaved = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        XCTAssertNil(CaptureChunkRing(format: interleaved, chunkFrames: 8))
    }

    /// One IO cycle: the left channel counts up from `start`, the right
    /// channel is its negation.
    private func write(_ ring: CaptureChunkRing, from start: Int, count: Int) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count {
            buffer.floatChannelData![0][frame] = Float(start + frame)
            buffer.floatChannelData![1][frame] = -Float(start + frame)
        }
        ring.write(
            UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
            frameCount: count
        )
    }
}
