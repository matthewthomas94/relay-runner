import Foundation
import XCTest
@testable import relay_runner

/// RR-462: the one-time cleanup of data left by the removed custom voices feature.
final class RetiredCustomVoiceCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr462-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)) != nil
    }

    func testRemovesExactlyTheRetiredPathsAndKeepsSharedFiles() throws {
        try write("services/custom-voice/venv/bin/python3")
        try write("custom-voice-runtime.json")
        try write("voices/0123/reference.wav")
        try write("voice-audio.lock")
        try write("services/.venv/bin/python3")
        try write("services/tts_worker.py")
        try write("config.toml")

        let removed = ProcessManager.removeRetiredCustomVoiceData(supportRoot: root)

        XCTAssertEqual(Set(removed), Set(ProcessManager.retiredCustomVoicePaths))
        for path in ProcessManager.retiredCustomVoicePaths { XCTAssertFalse(exists(path), path) }
        for path in ["voice-audio.lock", "services/.venv/bin/python3", "services/tts_worker.py", "config.toml"] {
            XCTAssertTrue(exists(path), path)
        }
    }

    func testIsANoOpWhenNothingIsLeft() throws {
        try write("voice-audio.lock")
        XCTAssertEqual(ProcessManager.removeRetiredCustomVoiceData(supportRoot: root), [])
        XCTAssertEqual(ProcessManager.removeRetiredCustomVoiceData(supportRoot: root.appendingPathComponent("missing")), [])
        XCTAssertTrue(exists("voice-audio.lock"))
    }

    func testRemovesASymlinkWithoutTouchingItsTarget() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("voices"), withDestinationURL: outside)

        XCTAssertEqual(ProcessManager.removeRetiredCustomVoiceData(supportRoot: root), ["voices"])
        XCTAssertFalse(exists("voices"))
        XCTAssertTrue(exists("outside/keep.txt"))
    }
}
