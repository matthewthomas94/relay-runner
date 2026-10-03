import AppKit
import FluidAudio
import XCTest
@testable import relay_runner

/// Drives the real STTEngine ownership path with a fake capture backend, a
/// controllable model load and a silent voice-output writer, so no test opens a
/// microphone or writes into the live bridge FIFO.
final class STTCaptureOwnershipTests: XCTestCase {
    private final class Backend: AudioCaptureBackend {
        var onConfigurationChange: ((String) -> Void)?
        private let lock = NSLock()
        private var _running = false
        private var _starts = 0
        var failNextStart = false

        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
        var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

        func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
            lock.lock(); defer { lock.unlock() }
            _starts += 1
            if failNextStart { failNextStart = false; throw AudioCaptureFailure.noInput }
            _running = true
            return AudioInputRoute(deviceID: 1, sampleRate: 48_000, channelCount: 1)
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            _running = false
        }
    }

    private final class Monitor: DefaultAudioInputMonitoring {
        var onDefaultInputChanged: (() -> Void)?
        func start() throws {}
        func stop() {}
    }

    /// Holds the model load until the test releases it.
    private final class ModelGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume(); return }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func write(_ line: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _lines.append(line)
            return true
        }
    }

    private var backend: Backend!
    private var output: Output!
    private var engines: [STTEngine] = []

    override func setUp() {
        super.setUp()
        backend = Backend()
        output = Output()
    }

    override func tearDown() {
        engines.forEach { $0.stop() }
        engines = []
        super.tearDown()
    }

    private func makeEngine(gate: ModelGate? = nil) -> STTEngine {
        let backend = backend!
        let output = output!
        var config = SttConfig()
        config.activation_key = "f13"
        let engine = STTEngine(config: config, dependencies: STTEngineDependencies(
            loadModel: { _, _ in
                await gate?.wait()
                return AsrManager()
            },
            makeCapture: { sampleHandler, isRecording in
                AudioCaptureLifecycle(
                    backend: backend,
                    routeMonitor: Monitor(),
                    recoveryDelay: 60,
                    sampleHandler: sampleHandler,
                    isRecording: isRecording
                )
            },
            makeGesture: { key in
                CapsLockGesture(
                    activationKey: key,
                    globalMonitorInstaller: { _, _ in nil },
                    localMonitorInstaller: { _, _ in nil },
                    monitorRemover: { _ in },
                    diagnosticLogger: { _ in }
                )
            },
            prepareVoiceOutput: {},
            writeVoiceOutput: { output.write($0) }
        ))
        engines.append(engine)
        return engine
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }

    // MARK: - Engine lifecycle

    func testModelReadyWithoutOwnerKeepsMicrophoneClosed() async throws {
        let engine = makeEngine()
        try await engine.start()
        XCTAssertEqual(engine.statusMessage, "Listening")
        XCTAssertEqual(backend.starts, 0)
        XCTAssertFalse(backend.isRunning)
    }

    func testSessionOwnershipOpensAndReleasesCaptureAcrossRepeatedSwitches() async throws {
        let engine = makeEngine()
        try await engine.start()
        for _ in 0..<3 {
            engine.setCaptureAllowed(true)
            engine.setCaptureAllowed(true) // Re-asserting the owner is a no-op.
            XCTAssertTrue(backend.isRunning)
            engine.setCaptureAllowed(false)
            XCTAssertFalse(backend.isRunning)
        }
        XCTAssertEqual(backend.starts, 3)
    }

    func testOwnerGrantedBeforeLateModelLoadOpensCaptureWhenModelIsReady() async throws {
        let gate = ModelGate()
        let engine = makeEngine(gate: gate)
        let start = Task { try await engine.start() }
        engine.setCaptureAllowed(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(backend.isRunning)
        gate.release()
        try await start.value
        XCTAssertTrue(backend.isRunning)
    }

    func testOwnerReleasedBeforeLateModelLoadNeverOpensCapture() async throws {
        let gate = ModelGate()
        let engine = makeEngine(gate: gate)
        let start = Task { try await engine.start() }
        engine.setCaptureAllowed(true)
        engine.setCaptureAllowed(false)
        gate.release()
        try await start.value
        XCTAssertEqual(backend.starts, 0)
    }

    func testModelLoadFinishingAfterStopNeverOpensCapture() async throws {
        let gate = ModelGate()
        let engine = makeEngine(gate: gate)
        engine.setCaptureAllowed(true)
        let start = Task { try await engine.start() }
        try await Task.sleep(for: .milliseconds(20))
        engine.stop()
        gate.release()
        try await start.value
        engine.setCaptureAllowed(false)
        engine.setCaptureAllowed(true) // A stale owner refresh cannot revive a stopped engine.
        XCTAssertEqual(backend.starts, 0)
        XCTAssertFalse(backend.isRunning)
    }

    func testStopReleasesCaptureHeldBySession() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        XCTAssertTrue(backend.isRunning)
        engine.stop()
        XCTAssertFalse(backend.isRunning)
    }

    func testReferenceAudioResumeAfterSessionEndsStaysClosed() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        let token = try engine.suspendForReferenceAudio()
        XCTAssertFalse(backend.isRunning)
        engine.setCaptureAllowed(false)
        engine.resumeAfterReferenceAudio(token)
        XCTAssertFalse(backend.isRunning)
        XCTAssertEqual(backend.starts, 1)
    }

    func testReferenceAudioResumeInsideSessionReopensCapture() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        let token = try engine.suspendForReferenceAudio()
        engine.setCaptureAllowed(true)
        XCTAssertFalse(backend.isRunning)
        engine.resumeAfterReferenceAudio(token)
        XCTAssertTrue(backend.isRunning)
    }

    func testCaptureStartFailureReportsUnavailableWithoutThrowingFromOwnerChange() async throws {
        let engine = makeEngine()
        try await engine.start()
        backend.failNextStart = true
        engine.setCaptureAllowed(true)
        XCTAssertFalse(backend.isRunning)
        XCTAssertTrue(output.lines.contains("__CONTINUITY__:capture_failed"))
    }

    // MARK: - Gestures

    func testOutOfSessionActivationRequestsSessionWithoutOpeningMicrophone() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.toggleRecording()
        try await waitUntil { engine.captureOwnerRequestedSerial == 1 }
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.recordingStartedSerial, 0)
        XCTAssertEqual(backend.starts, 0)
        XCTAssertFalse(output.lines.contains("__TTS_STOP__"))
    }

    func testInSessionActivationRecordsAndSessionEndCancelsIt() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 1 }
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(output.lines.contains("__TTS_STOP__"))
        XCTAssertEqual(engine.captureOwnerRequestedSerial, 0)

        engine.setCaptureAllowed(false)
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(backend.isRunning)
    }

    // MARK: - Onboarding practice

    private func practiceOnce(_ engine: STTEngine, expected: Int) async throws {
        engine.toggleRecording()
        try await waitUntil { engine.tutorialPracticeStartedSerial == expected }
        // Hold past the gesture's tap threshold so turning the key off sends.
        try await Task.sleep(for: .milliseconds(700))
        engine.toggleRecording()
        try await waitUntil { engine.tutorialPracticeSentSerial == expected }
    }

    private func assertMicrophoneNeverOpened(_ engine: STTEngine, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(backend.starts, 0, file: file, line: line)
        XCTAssertFalse(backend.isRunning, file: file, line: line)
        XCTAssertFalse(engine.isRecording, file: file, line: line)
        XCTAssertEqual(engine.recordingStartedSerial, 0, file: file, line: line)
        XCTAssertEqual(engine.captureOwnerRequestedSerial, 0, file: file, line: line)
        // Only engine startup status may reach the bridge: no __TTS_STOP__,
        // transcript, or interrupt is written for practice gestures.
        let delivered = output.lines.filter { !$0.hasPrefix("__STATUS__:") }
        XCTAssertEqual(delivered, [], file: file, line: line)
    }

    func testTutorialPracticeGesturesNeverOpenMicrophone() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.tutorialActive = true
        try await practiceOnce(engine, expected: 1)
        try await practiceOnce(engine, expected: 2)
        engine.cancelRecording()
        assertMicrophoneNeverOpened(engine)
    }

    func testTutorialOpenCloseAndRestartNeverOpensMicrophone() async throws {
        let engine = makeEngine()
        try await engine.start()
        for round in 1...3 {
            engine.tutorialActive = true
            try await practiceOnce(engine, expected: round)
            engine.tutorialActive = false
        }
        assertMicrophoneNeverOpened(engine)
    }

    func testLateModelStartupDuringTutorialNeverOpensMicrophone() async throws {
        let gate = ModelGate()
        let engine = makeEngine(gate: gate)
        engine.tutorialActive = true
        let start = Task { try await engine.start() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(backend.starts, 0)
        gate.release()
        try await start.value
        try await practiceOnce(engine, expected: 1)
        assertMicrophoneNeverOpened(engine)
    }

    func testIdleActivationAfterTutorialStillRequestsSession() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.tutorialActive = true
        try await practiceOnce(engine, expected: 1)
        engine.tutorialActive = false
        engine.toggleRecording()
        try await waitUntil { engine.captureOwnerRequestedSerial == 1 }
        XCTAssertEqual(engine.tutorialPracticeStartedSerial, 1)
        XCTAssertEqual(backend.starts, 0)
    }

    // MARK: - Ownership policy

    func testCommandCapturePolicyTreatsEverySessionOwnerAlike() {
        // Embedded and external bridge sessions, and the retained bridge during
        // provider reconnect, all reach AppState as an active session.
        XCTAssertTrue(AppState.commandCaptureAllowed(hasActiveSession: true, noteOwnsForeground: false))
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: false, noteOwnsForeground: false))
    }

    func testCommandCapturePolicyNeverOverlapsNoteCapture() {
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: true, noteOwnsForeground: true))
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: false, noteOwnsForeground: true))
    }
}
