import CoreAudio
import FluidAudio
import TrueWhisper
import XCTest
@testable import relay_runner

/// Drives the real Caps Lock loop with True Whisper on: an injected frame
/// source stands in for the camera and a fake audio backend proves the
/// microphone never opens. No test touches a real camera or microphone.
final class STTTrueWhisperCaptureTests: XCTestCase {
    private final class Backend: AudioCaptureBackend {
        var onConfigurationChange: ((String) -> Void)?
        private let lock = NSLock()
        private var _starts = 0
        var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

        func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
            lock.lock(); defer { lock.unlock() }
            _starts += 1
            return AudioInputRoute(deviceID: 1, sampleRate: 48_000, channelCount: 1)
        }

        func stop() {}
    }

    private final class Monitor: DefaultAudioInputMonitoring {
        var onDefaultInputChanged: ((AudioObjectID?) -> Void)?
        func start() throws {}
        func stop() {}
    }

    /// Thread-safe record of voice output and log lines.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func append(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
    }

    /// Replays recorded frames as soon as it starts, like a camera that sees a face.
    private final class ReplayFrameSource: FrameSource {
        var onFrame: LipGeometryHandler?
        private(set) var isRunning = false
        private(set) var starts = 0
        private(set) var stops = 0
        let frames: [[Double]]

        init(frames: [[Double]]) { self.frames = frames }

        func start() throws {
            starts += 1
            isRunning = true
            for (i, g) in frames.enumerated() { onFrame?(Double(i) / 30, g) }
        }

        func stop() {
            stops += 1
            isRunning = false
        }
    }

    private var backend: Backend!
    private var output: Lines!
    private var log: Lines!
    private var gesture: CapsLockGesture?
    private var sources: [ReplayFrameSource] = []
    private var modelLoads = 0
    private var engines: [STTEngine] = []

    override func setUp() {
        super.setUp()
        backend = Backend()
        output = Lines()
        log = Lines()
        sources = []
        modelLoads = 0
    }

    override func tearDown() {
        engines.forEach { $0.stop() }
        engines = []
        gesture = nil
        super.tearDown()
    }

    private func makeEngine(trueWhisper: Bool = true, templates: [Template], frames: [[Double]]) -> STTEngine {
        let backend = backend!
        let output = output!
        let log = log!
        var config = SttConfig()
        config.activation_key = "f13"
        config.true_whisper = trueWhisper
        var dependencies = STTEngineDependencies(
            loadModel: { [weak self] _, _ in
                self?.modelLoads += 1
                return AsrManager()
            },
            transcribe: { _, _ in "" },
            makeCapture: { sampleHandler, isRecording in
                AudioCaptureLifecycle(
                    backend: backend,
                    routeMonitor: Monitor(),
                    recoveryDelay: 60,
                    sampleHandler: sampleHandler,
                    isRecording: isRecording
                )
            },
            makeGesture: { [weak self] key in
                let gesture = CapsLockGesture(
                    activationKey: key,
                    globalMonitorInstaller: { _, _ in nil },
                    localMonitorInstaller: { _, _ in nil },
                    monitorRemover: { _ in },
                    diagnosticLogger: { _ in }
                )
                self?.gesture = gesture
                return gesture
            },
            prepareVoiceOutput: {},
            writeVoiceOutput: { output.append($0); return true }
        )
        dependencies.makeFrameSource = { [weak self] in
            let source = ReplayFrameSource(frames: frames)
            self?.sources.append(source)
            return source
        }
        dependencies.loadTrueWhisperTemplates = { templates }
        dependencies.log = { log.append($0) }
        let engine = STTEngine(config: config, dependencies: dependencies)
        engines.append(engine)
        return engine
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }

    /// Press, hold past the recording threshold, release.
    private func holdAndRelease(_ engine: STTEngine) async throws {
        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 1 }
        try await waitUntil { [weak self] in self?.gesture?.isRecording == true }
        engine.toggleRecording()
        try await waitUntil { !engine.isRecording && self.gesture?.isActivationHeld == false }
    }

    private static let templates = TrueWhisperFixtures.templates(perLabel: 3)

    // MARK: - Recognition

    func testHoldReadsLipsAndDeliversTheLabelWithoutOpeningTheMicrophone() async throws {
        let stop = Self.templates.first { $0.label == "stop" }!
        let engine = makeEngine(templates: Self.templates, frames: stop.frames)
        XCTAssertTrue(engine.usesTrueWhisper)
        try await engine.start()
        engine.setCaptureAllowed(true)

        try await holdAndRelease(engine)
        try await waitUntil { engine.deliveredTranscriptSerial == 1 }

        let lines = output.lines
        let ttsStop = try XCTUnwrap(lines.firstIndex(of: "__TTS_STOP__"))
        let label = try XCTUnwrap(lines.firstIndex(of: "stop"))
        XCTAssertLessThan(ttsStop, label)
        XCTAssertEqual(lines.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(backend.starts, 0, "the microphone backend must never start")
        XCTAssertEqual(modelLoads, 0, "the speech model is not needed for lip reading")
        XCTAssertEqual(sources.count, 1)
        XCTAssertFalse(sources[0].isRunning)
        XCTAssertGreaterThanOrEqual(sources[0].stops, 1)
        XCTAssertTrue(log.lines.contains { $0.contains("True Whisper decision label=stop") && $0.contains("accepted=true") })
    }

    func testUnmatchedFramesSendNothingAndReportAStatus() async throws {
        // Fast, large, irregular movement unlike any enrolled word.
        let noise = (0..<30).map { i in (0..<6).map { k in Double((i * 7 + k * 13) % 11) * (i.isMultiple(of: 2) ? 1 : -1) } }
        let classifier = try XCTUnwrap(TemplateClassifier(templates: Self.templates))
        XCTAssertFalse(classifier.predict(noise, maxDistance: 1.5, minConfidence: 0.1).accepted)

        let engine = makeEngine(templates: Self.templates, frames: noise)
        try await engine.start()
        engine.setCaptureAllowed(true)
        try await holdAndRelease(engine)
        try await waitUntil { self.output.lines.contains("__STATUS__:True Whisper: no confident match") }

        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
        XCTAssertFalse(output.lines.contains("stop"))
        XCTAssertFalse(output.lines.contains("cancel"))
        XCTAssertEqual(engine.statusMessage, "True Whisper: no confident match")
        XCTAssertEqual(backend.starts, 0)
        XCTAssertFalse(sources[0].isRunning)
        XCTAssertGreaterThanOrEqual(sources[0].stops, 1)
    }

    func testTooFewFramesReportNoFace() async throws {
        let engine = makeEngine(templates: Self.templates, frames: Array(TrueWhisperFixtures.word(phase: 0, frames: 28).prefix(3)))
        try await engine.start()
        engine.setCaptureAllowed(true)
        try await holdAndRelease(engine)
        try await waitUntil { self.output.lines.contains("__STATUS__:True Whisper: no face seen") }
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
        XCTAssertFalse(sources[0].isRunning)
    }

    func testEndingTheSessionMidHoldTurnsTheCameraOff() async throws {
        let stop = Self.templates.first { $0.label == "stop" }!
        let engine = makeEngine(templates: Self.templates, frames: stop.frames)
        try await engine.start()
        engine.setCaptureAllowed(true)
        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 1 }
        XCTAssertTrue(sources[0].isRunning)

        engine.setCaptureAllowed(false)
        try await waitUntil { self.sources[0].isRunning == false }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.deliveredTranscriptSerial, 0)
        XCTAssertFalse(output.lines.contains("stop"))
    }

    // MARK: - Fallback and reconfiguration

    func testFewerThanTwoEnrolledWordsFallsBackToTheMicrophoneAndLogsOnce() async throws {
        // One word enrolled; "cancel" has only two takes, below the enrolled threshold.
        var templates = Self.templates.filter { $0.label == "stop" }
        templates += Self.templates.filter { $0.label == "cancel" }.prefix(2)
        let engine = makeEngine(templates: templates, frames: [])
        XCTAssertFalse(engine.usesTrueWhisper)
        try await engine.start()
        engine.setCaptureAllowed(true)
        XCTAssertEqual(backend.starts, 1, "fallback opens the microphone as today")
        XCTAssertEqual(modelLoads, 1)

        engine.toggleRecording()
        try await waitUntil { engine.recordingStartedSerial == 1 }
        XCTAssertTrue(sources.isEmpty, "no camera in microphone mode")
        XCTAssertEqual(log.lines.filter { $0.contains("fewer than 2 words are enrolled") }.count, 1)
    }

    func testTrueWhisperOffKeepsTheMicrophonePath() async throws {
        let engine = makeEngine(trueWhisper: false, templates: Self.templates, frames: [])
        XCTAssertFalse(engine.usesTrueWhisper)
        try await engine.start()
        engine.setCaptureAllowed(true)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertTrue(log.lines.isEmpty)
    }

    func testTogglingTrueWhisperThroughSaveConfigRebuildsTheEngineOnTheCameraPath() {
        var off = SttConfig()
        off.activation_key = "f13"
        var on = off
        on.true_whisper = true
        // persistConfig restarts STT through this decision, then builds a
        // fresh engine from the saved config.
        XCTAssertTrue(AppState.sttSettingsRequireRestart(old: off, new: on))
        XCTAssertTrue(AppState.sttSettingsRequireRestart(old: on, new: off))
        XCTAssertFalse(AppState.sttSettingsRequireRestart(old: on, new: on))

        XCTAssertFalse(makeEngine(trueWhisper: false, templates: Self.templates, frames: []).usesTrueWhisper)
        XCTAssertTrue(makeEngine(trueWhisper: true, templates: Self.templates, frames: []).usesTrueWhisper)
    }
}
