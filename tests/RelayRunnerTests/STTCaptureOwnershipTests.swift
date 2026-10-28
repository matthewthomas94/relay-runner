import AppKit
import CoreAudio
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
        var onDefaultInputChanged: ((AudioObjectID?) -> Void)?
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

    /// Fake snapshot recognizer: records each snapshot length and, while
    /// holding, parks every call until the test releases it.
    private final class Recognizer: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        private var _holding = false
        private var _snapshots: [Int] = []
        private var parked: [CheckedContinuation<Void, Never>] = []

        var text: String {
            get { lock.lock(); defer { lock.unlock() }; return _text }
            set { lock.lock(); _text = newValue; lock.unlock() }
        }
        var holding: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _holding }
            set { lock.lock(); _holding = newValue; lock.unlock() }
        }
        var snapshots: [Int] { lock.lock(); defer { lock.unlock() }; return _snapshots }
        var parkedCount: Int { lock.lock(); defer { lock.unlock() }; return parked.count }

        func transcribe(_ audio: [Float]) async -> String {
            await withCheckedContinuation { continuation in
                lock.lock()
                _snapshots.append(audio.count)
                if _holding {
                    parked.append(continuation)
                    lock.unlock()
                } else {
                    lock.unlock()
                    continuation.resume()
                }
            }
            return text
        }

        func releaseParked() {
            lock.lock()
            let released = parked
            parked = []
            lock.unlock()
            released.forEach { $0.resume() }
        }
    }

    private var backend: Backend!
    private var output: Output!
    private var recognizer: Recognizer!
    /// The engine's capture sink, so tests feed samples as the microphone would.
    private var feed: (([Float]) -> Void)?
    private var engines: [STTEngine] = []

    override func setUp() {
        super.setUp()
        backend = Backend()
        output = Output()
        recognizer = Recognizer()
    }

    override func tearDown() {
        recognizer.holding = false
        recognizer.releaseParked()
        feed = nil
        engines.forEach { $0.stop() }
        engines = []
        super.tearDown()
    }

    private func makeEngine(gate: ModelGate? = nil) -> STTEngine {
        let backend = backend!
        let output = output!
        let recognizer = recognizer!
        var config = SttConfig()
        config.activation_key = "f13"
        let engine = STTEngine(config: config, dependencies: STTEngineDependencies(
            loadModel: { _, _ in
                await gate?.wait()
                return AsrManager()
            },
            transcribe: { _, audio in await recognizer.transcribe(audio) },
            makeCapture: { [weak self] sampleHandler, isRecording in
                self?.feed = sampleHandler
                return AudioCaptureLifecycle(
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

    func testRemoteDeviceSuspendsThenResumesCapture() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        XCTAssertTrue(backend.isRunning)
        engine.suspendForRemoteDevice()
        XCTAssertFalse(backend.isRunning)
        engine.setCaptureAllowed(true)
        XCTAssertFalse(backend.isRunning)
        engine.resumeAfterRemoteDevice()
        XCTAssertTrue(backend.isRunning)
    }

    func testReferenceAudioThenRemoteResumesOnlyAfterBoth() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        let token = try engine.suspendForReferenceAudio()
        engine.suspendForRemoteDevice()
        engine.resumeAfterReferenceAudio(token)
        XCTAssertFalse(backend.isRunning)
        engine.resumeAfterRemoteDevice()
        XCTAssertTrue(backend.isRunning)
    }

    func testRemoteThenReferenceAudioResumesOnlyAfterBoth() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        engine.suspendForRemoteDevice()
        let token = try engine.suspendForReferenceAudio()
        engine.resumeAfterRemoteDevice()
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

    func testWheelRecordingKeepsItsRequestedSessionAcrossAFocusChange() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        engine.voiceTargetSessionKey = "session-a"
        engine.toggleRecording(forSessionKey: "session-a")
        engine.voiceTargetSessionKey = "session-b"
        try await waitUntil { engine.recordingStartedSerial == 1 }
        XCTAssertEqual(engine.recordingVoiceTargetSessionKey, "session-a")
        XCTAssertTrue(output.lines.contains("__VOICE_TARGET__:session-a"))
        XCTAssertFalse(output.lines.contains("__VOICE_TARGET__:session-b"))
        engine.toggleRecording(forSessionKey: "session-a")
        try await waitUntil { !engine.isRecording }
        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 2 }
        XCTAssertEqual(engine.recordingVoiceTargetSessionKey, "session-b")
    }

    func testCancellingAWheelRequestBeforeModelLoadDoesNotLeakItsTarget() async throws {
        let gate = ModelGate()
        let engine = makeEngine(gate: gate)
        let start = Task { try await engine.start() }
        engine.setCaptureAllowed(true)
        engine.toggleRecording(forSessionKey: "session-a")
        XCTAssertEqual(engine.recordingVoiceTargetSessionKey, "session-a")
        engine.cancelRecording()
        engine.voiceTargetSessionKey = "session-b"
        gate.release()
        try await start.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.recordingStartedSerial, 0)
        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 1 }
        XCTAssertEqual(engine.recordingVoiceTargetSessionKey, "session-b")
    }

    func testWheelMeterTracksSpeechOnlyForTheRecordingOwnerAndClearsOnCancel() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        engine.voiceTargetSessionKey = "session-a"
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 0)
        try await startRecording(engine)

        feed?([Float](repeating: 0.01, count: 1_600))
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 0.2, accuracy: 0.0001)
        engine.voiceTargetSessionKey = "session-b"
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-b"), 0)
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 0.2, accuracy: 0.0001)
        feed?([Float](repeating: 0, count: 1_600))
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 0)
        feed?(speech(seconds: 0.1))
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 1)
        engine.cancelRecording()
        XCTAssertEqual(engine.recordingLevel(forSessionKey: "session-a"), 0)
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
    }

    // MARK: - Command delivery

    private func speech(seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * 16_000))
    }

    /// Starts a Caps Lock recording and waits out the media settle.
    private func startRecording(_ engine: STTEngine) async throws {
        engine.toggleRecording()
        try await waitUntil { engine.partialTranscription == "Preparing\u{2026}" }
        try await waitUntil { engine.partialTranscription.isEmpty }
    }

    private func deliveries(of text: String) -> Int {
        output.lines.filter { $0 == text }.count
    }

    func testReleaseDeliversTheFinalTranscriptExactlyOnce() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        recognizer.text = "Open the board."
        try await startRecording(engine)
        feed?(speech(seconds: 1.2))
        try await waitUntil { engine.speechDetectedSerial >= 1 }
        XCTAssertEqual(engine.partialTranscription, "Open the board.")
        XCTAssertEqual(deliveries(of: "Open the board."), 0)

        engine.toggleRecording()
        try await waitUntil { engine.deliveredTranscriptSerial == 1 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(deliveries(of: "Open the board."), 1)
        XCTAssertEqual(engine.deliveredTranscriptSerial, 1)
        XCTAssertFalse(engine.isRecording)
    }

    func testTutorialConsumesTheFinalTranscriptLocally() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.tutorialActive = true
        engine.setCaptureAllowed(true)
        recognizer.text = "Open the board."
        try await startRecording(engine)
        feed?(speech(seconds: 1.2))
        try await waitUntil { engine.speechDetectedSerial >= 1 }
        engine.toggleRecording()
        try await waitUntil { engine.tutorialTranscriptSerial == 1 }
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
        XCTAssertEqual(deliveries(of: "Open the board."), 0)
    }

    func testSilenceFilterDropsPhantomPhraseAtRelease() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        recognizer.text = "Thank you."
        try await startRecording(engine)
        feed?(speech(seconds: 1.2))
        // A partial inference proves the hold registered, so the toggle is a release.
        try await waitUntil { self.recognizer.snapshots.count >= 1 }
        engine.toggleRecording()
        try await waitUntil { !engine.isRecording }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
        XCTAssertEqual(deliveries(of: "Thank you."), 0)
    }

    /// Parks the final inference, applies `interrupt`, then lets it finish.
    private func assertInterruptedFinalIsDropped(
        _ interrupt: (STTEngine) async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        recognizer.text = "Dispatch the ready ticket."
        try await startRecording(engine)
        recognizer.holding = true
        feed?(speech(seconds: 1.2))
        // The first parked call is a partial; releasing it after the stop
        // gesture lets the loop reach the final inference, which parks next.
        try await waitUntil { self.recognizer.parkedCount == 1 }
        engine.toggleRecording()
        recognizer.releaseParked()
        try await waitUntil { self.recognizer.snapshots.count == 2 && self.recognizer.parkedCount == 1 }
        XCTAssertEqual(engine.partialTranscription, "Dispatch the ready ticket.", file: file, line: line)
        let statusesBefore = output.lines.filter { $0.hasPrefix("__STATUS__:(refining)") }.count
        try await interrupt(engine)
        recognizer.holding = false
        recognizer.releaseParked()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0, file: file, line: line)
        XCTAssertEqual(deliveries(of: "Dispatch the ready ticket."), 0, file: file, line: line)
        XCTAssertEqual(output.lines.filter { $0.hasPrefix("__STATUS__:(refining)") }.count, statusesBefore,
                       file: file, line: line)
        XCTAssertFalse(engine.isRecording, file: file, line: line)
    }

    func testCancelDuringFinalInferenceDeliversNothing() async throws {
        try await assertInterruptedFinalIsDropped { $0.cancelRecording() }
    }

    func testStopDuringFinalInferenceDeliversNothing() async throws {
        try await assertInterruptedFinalIsDropped { $0.stop() }
    }

    func testSwitchingToNotesDuringFinalInferenceDeliversNothing() async throws {
        try await assertInterruptedFinalIsDropped { engine in
            engine.setCaptureAllowed(AppState.commandCaptureAllowed(
                hasActiveSession: true, sessionControlsTutorialActive: false, noteOwnsForeground: true
            ))
        }
    }

    func testDeviceChangeDuringFinalInferenceDeliversNothing() async throws {
        try await assertInterruptedFinalIsDropped { _ in
            self.backend.onConfigurationChange?("engine-configuration")
            // Route recovery announces the reconfiguration on its own queue.
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testCancelDuringPartialInferencePublishesNothing() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        recognizer.text = "Open the"
        try await startRecording(engine)
        recognizer.holding = true
        feed?(speech(seconds: 1.2))
        try await waitUntil { self.recognizer.parkedCount == 1 }
        engine.cancelRecording()
        recognizer.holding = false
        recognizer.releaseParked()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.speechDetectedSerial, 0)
        XCTAssertEqual(engine.partialTranscription, "")
        XCTAssertFalse(output.lines.contains { $0.hasPrefix("__STATUS__:(refining)") })
        XCTAssertFalse(engine.isRecording)
    }

    func testSilentChunkStillRollsOverSoSnapshotsStayBounded() async throws {
        let engine = makeEngine()
        try await engine.start()
        engine.setCaptureAllowed(true)
        recognizer.text = ""
        try await startRecording(engine)
        feed?(speech(seconds: 26))
        try await waitUntil { self.recognizer.snapshots.count >= 2 }
        let snapshots = recognizer.snapshots
        XCTAssertGreaterThanOrEqual(snapshots[0], 25 * 16_000)
        // The next snapshot holds only the one-second overlap.
        XCTAssertEqual(snapshots[1], 16_000)
        engine.toggleRecording()
        try await waitUntil { !engine.isRecording }
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
    }

    // MARK: - Ownership policy

    func testEndingTutorialReleasesCaptureUnlessProviderSessionRemains() async throws {
        let engine = makeEngine()
        try await engine.start()
        for providerSessionActive in [false, true] {
            engine.tutorialActive = true
            engine.setCaptureAllowed(AppState.commandCaptureAllowed(
                hasActiveSession: providerSessionActive,
                sessionControlsTutorialActive: true,
                noteOwnsForeground: false
            ))
            XCTAssertTrue(backend.isRunning)

            engine.tutorialActive = false
            // Repeated ownership refreshes after the tutorial's speech stops
            // must not reopen capture merely because its final screen remains.
            for _ in 0..<3 {
                engine.setCaptureAllowed(AppState.commandCaptureAllowed(
                    hasActiveSession: providerSessionActive,
                    sessionControlsTutorialActive: false,
                    noteOwnsForeground: false
                ))
                XCTAssertEqual(backend.isRunning, providerSessionActive)
            }
            engine.setCaptureAllowed(false)
        }
        XCTAssertEqual(backend.starts, 2)
    }

    func testCommandCapturePolicyTreatsEverySessionOwnerAlike() {
        // Embedded and external bridge sessions, and the retained bridge during
        // provider reconnect, all reach AppState as an active session.
        XCTAssertTrue(AppState.commandCaptureAllowed(hasActiveSession: true, sessionControlsTutorialActive: false, noteOwnsForeground: false))
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: false, sessionControlsTutorialActive: false, noteOwnsForeground: false))
    }

    func testCommandCapturePolicyNeverOverlapsNoteCapture() {
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: true, sessionControlsTutorialActive: false, noteOwnsForeground: true))
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: false, sessionControlsTutorialActive: true, noteOwnsForeground: true))
    }

    func testCommandCapturePolicyAllowsOnlyTheSessionControlsTutorialWhileIdle() {
        XCTAssertTrue(AppState.commandCaptureAllowed(hasActiveSession: false, sessionControlsTutorialActive: true, noteOwnsForeground: false))
    }

    func testCommandCapturePolicyRefusesASessionStillStartingUp() {
        // Nothing is ready to accept a command until the session's bridge is seen.
        XCTAssertFalse(AppState.commandCaptureAllowed(hasActiveSession: true, sessionControlsTutorialActive: false,
                                                      noteOwnsForeground: false, sessionStartingUp: true))
        XCTAssertTrue(AppState.commandCaptureAllowed(hasActiveSession: false, sessionControlsTutorialActive: true,
                                                     noteOwnsForeground: false, sessionStartingUp: true))
    }
}
