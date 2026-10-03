import Foundation
import XCTest
@testable import relay_runner

@MainActor
final class VoiceSampleRecorderTests: XCTestCase {
    final class FakeRecorder: VoiceSampleRecording {
        var isRecording = false
        var currentTime: TimeInterval = 6
        var starts = 0
        var stops = 0
        var accepts = true
        func record(forDuration duration: TimeInterval) -> Bool {
            XCTAssertEqual(duration, 10)
            starts += 1
            isRecording = accepts
            return accepts
        }
        func stop() { isRecording = false; stops += 1 }
    }

    private func settle(_ recorder: VoiceSampleRecorder) async throws {
        for _ in 0..<100 {
            if !recorder.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Recording did not resolve")
    }

    func testDeniedPermissionNeverAcquiresMicrophoneOrDelivers() async throws {
        var acquired = false
        let recorder = VoiceSampleRecorder(factory: { _ in XCTFail("Must not create recorder"); return FakeRecorder() })
        recorder.record(requestPermission: { $0(false) }, acquire: { acquired = true; return {} },
                        permissionStillGranted: { false }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        try await settle(recorder)
        XCTAssertFalse(acquired)
        XCTAssertNotNil(recorder.error)
    }

    func testCancelWhilePermissionPendingNeverStartsCapture() async throws {
        var permission: ((Bool) -> Void)?
        let recorder = VoiceSampleRecorder()
        recorder.record(requestPermission: { permission = $0 }, acquire: { XCTFail("Must not acquire"); return {} },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        recorder.cancel()
        permission?(true)
        try await settle(recorder)
        XCTAssertNil(recorder.error)
    }

    func testSuccessfulStopRestoresOwnershipAndDeletesRecording() async throws {
        let backend = FakeRecorder()
        var restored = 0
        var path: URL?
        var delivered = 0
        let recorder = VoiceSampleRecorder(factory: { url in path = url; return backend },
                                            decode: { _ in [Float](repeating: 0.2, count: 144_000) })
        recorder.record(requestPermission: { $0(true) }, acquire: { { restored += 1 } },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { delivered = $0.count })
        try await Task.sleep(for: .milliseconds(30))
        recorder.stop()
        try await settle(recorder)
        XCTAssertEqual(delivered, 144_000)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(path).deletingLastPathComponent().path))
    }

    func testCancelRecordingDiscardsDataAndRestoresExactlyOnce() async throws {
        let backend = FakeRecorder()
        var restored = 0
        let recorder = VoiceSampleRecorder(factory: { _ in backend }, decode: { _ in XCTFail("Must not decode"); return [] })
        recorder.record(requestPermission: { $0(true) }, acquire: { { restored += 1 } },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        try await Task.sleep(for: .milliseconds(30))
        recorder.cancel()
        recorder.cancel() // Closing an already cancelled panel remains idempotent.
        try await settle(recorder)
        XCTAssertEqual(restored, 1)
        XCTAssertNil(recorder.error)
    }

    func testDeviceStartFailureRestoresPriorOwner() async throws {
        let backend = FakeRecorder()
        backend.accepts = false
        var restored = 0
        let recorder = VoiceSampleRecorder(factory: { _ in backend })
        recorder.record(requestPermission: { $0(true) }, acquire: { { restored += 1 } },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        try await settle(recorder)
        XCTAssertEqual(restored, 1)
        XCTAssertNotNil(recorder.error)
    }

    func testPermissionRevokedDuringCaptureDiscardsAndRestores() async throws {
        let backend = FakeRecorder()
        var permission = true
        var restored = 0
        let recorder = VoiceSampleRecorder(factory: { _ in backend }, decode: { _ in XCTFail("Must not decode"); return [] })
        recorder.record(requestPermission: { $0(true) }, acquire: { { restored += 1 } },
                        permissionStillGranted: { permission }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        try await Task.sleep(for: .milliseconds(30))
        permission = false
        try await settle(recorder)
        XCTAssertEqual(restored, 1)
        XCTAssertNotNil(recorder.error)
    }

    func testBusySessionNeverCreatesSecondCapture() async throws {
        let recorder = VoiceSampleRecorder(factory: { _ in XCTFail("Must not create recorder"); return FakeRecorder() })
        recorder.record(requestPermission: { $0(true) }, acquire: { throw CustomVoiceFailure.busy },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { _ in XCTFail("Must not deliver") })
        try await settle(recorder)
        XCTAssertNotNil(recorder.error)
    }

    func testTenSecondCapStopsAndPassesOnlyBoundedSamples() async throws {
        let backend = FakeRecorder()
        var checks = 0
        var delivered = 0
        let recorder = VoiceSampleRecorder(factory: { _ in backend }, decode: { _ in [Float](repeating: 0.2, count: 264_000) },
                                            clock: { checks += 1; return Date(timeIntervalSince1970: checks == 1 ? 0 : 11) })
        recorder.record(requestPermission: { $0(true) }, acquire: { {} },
                        permissionStillGranted: { true }, sessionActive: { true },
                        completion: { delivered = $0.count })
        try await settle(recorder)
        XCTAssertEqual(delivered, 240_000)
        XCTAssertFalse(backend.isRecording)
    }
    func testRecordingOutsideSessionIsBlockedBeforePermissionPrompt() async throws {
        var prompted = false
        let recorder = VoiceSampleRecorder(factory: { _ in XCTFail("Must not create recorder"); return FakeRecorder() })
        recorder.record(requestPermission: { prompted = true; $0(true) }, acquire: { XCTFail("Must not acquire"); return {} },
                        permissionStillGranted: { true }, sessionActive: { false },
                        completion: { _ in XCTFail("Must not deliver") })
        try await settle(recorder)
        XCTAssertFalse(prompted)
        XCTAssertEqual(recorder.error, CustomVoiceFailure.sessionRequired.localizedDescription)
    }

    func testPermissionGrantedAfterSessionEndsNeverAcquiresMicrophone() async throws {
        var permission: ((Bool) -> Void)?
        var session = true
        let recorder = VoiceSampleRecorder(factory: { _ in XCTFail("Must not create recorder"); return FakeRecorder() })
        recorder.record(requestPermission: { permission = $0 }, acquire: { XCTFail("Must not acquire"); return {} },
                        permissionStillGranted: { true }, sessionActive: { session },
                        completion: { _ in XCTFail("Must not deliver") })
        session = false
        permission?(true)
        try await settle(recorder)
        XCTAssertEqual(recorder.error, CustomVoiceFailure.sessionRequired.localizedDescription)
    }

    func testSessionEndingDuringCaptureDiscardsAndRestoresOnce() async throws {
        let backend = FakeRecorder()
        var session = true
        var restored = 0
        let recorder = VoiceSampleRecorder(factory: { _ in backend }, decode: { _ in XCTFail("Must not decode"); return [] })
        recorder.record(requestPermission: { $0(true) }, acquire: { { restored += 1 } },
                        permissionStillGranted: { true }, sessionActive: { session },
                        completion: { _ in XCTFail("Must not deliver") })
        try await Task.sleep(for: .milliseconds(30))
        session = false
        try await settle(recorder)
        XCTAssertEqual(restored, 1)
        XCTAssertFalse(backend.isRecording)
        XCTAssertEqual(recorder.error, CustomVoiceFailure.sessionRequired.localizedDescription)
    }
}
