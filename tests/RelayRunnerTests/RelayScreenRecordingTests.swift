import Foundation
import XCTest
@testable import relay_runner

final class RelayScreenRecordingTests: XCTestCase {
    private let temporary = URL(fileURLWithPath: "/tmp/relay-vision-tests", isDirectory: true)
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecordRequestDefaultsMatchTheToolDescription() {
        let request = RelayScreenRecordingRequest(arguments: [:], now: fixedDate, temporaryDirectory: temporary)

        XCTAssertEqual(request.duration, 4)
        XCTAssertEqual(request.framesPerSecond, 15)
        XCTAssertEqual(request.displayIndex, 0)
        XCTAssertEqual(request.frameCount, 60)
        XCTAssertEqual(request.outputURL.deletingLastPathComponent().path, temporary.path)
        XCTAssertTrue(request.outputURL.lastPathComponent.hasPrefix("relay-vision-"))
        XCTAssertEqual(request.outputURL.pathExtension, "mp4")
        XCTAssertEqual(
            request.outputURL.lastPathComponent,
            RelayScreenRecordingRequest.defaultFileName(now: fixedDate)
        )
    }

    func testRecordRequestClampsDurationAndFrameRate() {
        let long = RelayScreenRecordingRequest(
            arguments: ["duration_seconds": 120, "fps": 90, "display_index": 1],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(long.duration, 30)
        XCTAssertEqual(long.framesPerSecond, 30)
        XCTAssertEqual(long.displayIndex, 1)
        XCTAssertEqual(long.frameCount, 900)

        let short = RelayScreenRecordingRequest(
            arguments: ["duration_seconds": 0.1, "fps": 0],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(short.duration, 0.5)
        XCTAssertEqual(short.framesPerSecond, 1)
        XCTAssertEqual(short.frameCount, 1)

        let fractional = RelayScreenRecordingRequest(
            arguments: ["duration_seconds": 2.5, "fps": 12.0],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(fractional.duration, 2.5)
        XCTAssertEqual(fractional.framesPerSecond, 12)
        XCTAssertEqual(fractional.frameCount, 30)

        let invalid = RelayScreenRecordingRequest(
            arguments: ["duration_seconds": "soon", "fps": "fast"],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(invalid.duration, 4)
        XCTAssertEqual(invalid.framesPerSecond, 15)
    }

    func testRecordRequestHonoursOutputPathAndForcesMP4() {
        let explicit = RelayScreenRecordingRequest(
            arguments: ["output_path": "~/Movies/sketch.mp4"],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(explicit.outputURL.path, NSHomeDirectory() + "/Movies/sketch.mp4")

        let bare = RelayScreenRecordingRequest(
            arguments: ["output_path": "/tmp/relay-vision-tests/take-one"],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(bare.outputURL.path, "/tmp/relay-vision-tests/take-one.mp4")

        let blank = RelayScreenRecordingRequest(
            arguments: ["output_path": "  "],
            now: fixedDate, temporaryDirectory: temporary
        )
        XCTAssertEqual(blank.outputURL.deletingLastPathComponent().path, temporary.path)
    }

    func testRecordingFramesKeepTheScreenshotCeilingAndEvenEdges() {
        let retina = RelayScreenRecordingRequest.outputSize(nativeWidth: 3024, nativeHeight: 1964)
        XCTAssertEqual(retina.width, 2000)
        XCTAssertEqual(retina.height, 1298)

        let portrait = RelayScreenRecordingRequest.outputSize(nativeWidth: 1080, nativeHeight: 3840)
        XCTAssertEqual(portrait.height, 2000)
        XCTAssertEqual(portrait.width, 562)

        let small = RelayScreenRecordingRequest.outputSize(nativeWidth: 1281, nativeHeight: 801)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 800)
    }

    func testRecordIsHostedBehindScreenRecording() {
        XCTAssertEqual(RelayHostedTool.requiredPermission(for: "record"), .screenRecording)
        XCTAssertEqual(RelayHostedTool.requiredPermission(for: "screenshot"), .screenRecording)
    }
}
