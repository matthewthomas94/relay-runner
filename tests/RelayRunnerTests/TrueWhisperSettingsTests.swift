import Foundation
import XCTest
@testable import relay_runner
@testable import TrueWhisper

@MainActor
final class TrueWhisperEnrollmentTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-settings-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> TemplateStore { TemplateStore(url: dir.appendingPathComponent("templates.json")) }

    private static let timing = TrueWhisperEnrollment.Timing(
        takeSeconds: 1.5, countdownStepSeconds: 0.7, facePollSeconds: 0.1, faceTimeoutSeconds: 1)

    /// The take window pushes `framesPerTake[k]` frames for the k-th take.
    private func makeEnrollment(
        source: PushFrameSource,
        framesPerTake: [Int],
        onTake: ((Int) -> Void)? = nil
    ) -> (TrueWhisperEnrollment, () -> [String]) {
        var takeIndex = 0
        var cues: [String] = []
        let enrollment = TrueWhisperEnrollment(
            store: store(),
            timing: Self.timing,
            makeSource: { source },
            speak: { cues.append($0) },
            sleep: { seconds in
                try Task.checkCancellation()
                guard seconds == Self.timing.takeSeconds else { return }
                let count = takeIndex < framesPerTake.count ? framesPerTake[takeIndex] : 30
                source.push(count)
                takeIndex += 1
                onTake?(takeIndex)
            })
        return (enrollment, { cues })
    }

    func testRecordsTenTakesDiscardsShortOnesAndReleasesSource() async throws {
        let source = PushFrameSource(framesOnStart: 1)
        // Takes 2 and 5 are short (fewer than 6 frames) and are retried.
        let (enrollment, cues) = makeEnrollment(source: source, framesPerTake: [30, 5, 30, 30, 0, 30])
        enrollment.record("stop")
        XCTAssertTrue(enrollment.isRecording)
        await enrollment.waitUntilIdle()

        let stored = store().load()
        XCTAssertEqual(stored.count, 10)
        XCTAssertTrue(stored.allSatisfy { $0.label == "stop" && $0.frames.count == 30 })
        XCTAssertEqual(enrollment.counts["stop"], 10)
        XCTAssertEqual(enrollment.discardedTakes, 2)
        XCTAssertNil(enrollment.failure)
        XCTAssertFalse(enrollment.isRecording)
        XCTAssertEqual(enrollment.phase, .idle)
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertGreaterThanOrEqual(source.stopCount, 1)
        // Each of the 12 attempts: the word, then 3, 2, 1.
        XCTAssertEqual(Array(cues().prefix(4)), ["stop", "3", "2", "1"])
        XCTAssertEqual(cues().count, 12 * 4)
    }

    func testStopKeepsPartialTakesAndReleasesSource() async throws {
        let source = PushFrameSource(framesOnStart: 1)
        var enrollmentRef: TrueWhisperEnrollment?
        let (enrollment, _) = makeEnrollment(source: source, framesPerTake: [], onTake: { take in
            if take == 3 { enrollmentRef?.stop() }
        })
        enrollmentRef = enrollment
        enrollment.record("cancel")
        await enrollment.waitUntilIdle()

        // The third take's window completed before Stop was noticed, so it is kept.
        XCTAssertEqual(store().load().count, 3)
        XCTAssertEqual(enrollment.counts["cancel"], 3)
        XCTAssertNil(enrollment.failure)
        XCTAssertFalse(enrollment.isRecording)
        XCTAssertFalse(source.isRunning)
        XCTAssertGreaterThanOrEqual(source.stopCount, 1)
    }

    func testNoFaceFailsAndReleasesSource() async {
        let source = PushFrameSource(framesOnStart: 0)
        let (enrollment, _) = makeEnrollment(source: source, framesPerTake: [])
        enrollment.record("play")
        await enrollment.waitUntilIdle()
        XCTAssertEqual(enrollment.failure, .noFace)
        XCTAssertEqual(store().load(), [])
        XCTAssertFalse(source.isRunning)
    }

    func testSourceStartFailureReportsCamera() async {
        let source = PushFrameSource(framesOnStart: 1, startError: LipCaptureError.notAuthorized)
        let (enrollment, _) = makeEnrollment(source: source, framesPerTake: [])
        enrollment.record("play")
        await enrollment.waitUntilIdle()
        XCTAssertEqual(enrollment.failure, .camera)
        XCTAssertFalse(source.isRunning)
    }

    func testClearAllEmptiesStore() throws {
        try store().save(TrueWhisperFixtures.templates(perLabel: 2))
        let enrollment = TrueWhisperEnrollment(store: store())
        enrollment.reloadCounts()
        XCTAssertEqual(enrollment.counts, ["stop": 2, "cancel": 2])
        try enrollment.clearAll()
        XCTAssertEqual(store().load(), [])
        XCTAssertEqual(enrollment.counts, [:])
    }
}

@MainActor
final class TrueWhisperSettingsModelTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-model-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func model(
        permission: FakeCameraPermission = FakeCameraPermission(.granted),
        templates: [Template] = [],
        evaluate: @escaping @Sendable ([Template]) -> Evaluation? = { Evaluation.run(templates: $0, permutations: 100) }
    ) throws -> TrueWhisperSettingsModel {
        let store = TemplateStore(url: dir.appendingPathComponent("templates.json"))
        try store.save(templates)
        return TrueWhisperSettingsModel(
            permission: permission, enrollment: TrueWhisperEnrollment(store: store), evaluate: evaluate)
    }

    func testReadoutNeedsTwoWordsWithThreeTakesAndRunsOffMain() async throws {
        let mainFlags = MainThreadFlags()
        let evaluate: @Sendable ([Template]) -> Evaluation? = { templates in
            mainFlags.record(Thread.isMainThread)
            return Evaluation.run(templates: templates, permutations: 100)
        }

        // stop x3, cancel x2: only one word is enrolled.
        let three = TrueWhisperFixtures.templates(perLabel: 3)
        var notReady = three
        notReady.remove(at: notReady.lastIndex { $0.label == "cancel" }!)
        let early = try model(templates: notReady, evaluate: evaluate)
        early.onAppear()
        await early.waitForReadout()
        XCTAssertEqual(early.readout, .needsEnrollment)
        XCTAssertEqual(early.readout.description, "Enrol at least two words to test")
        XCTAssertFalse(early.enrollment.isReady)
        XCTAssertTrue(mainFlags.values.isEmpty)

        // stop x6, cancel x6, plus one play take that is left out of the test.
        let six = TrueWhisperFixtures.templates(perLabel: 6)
        let ready = try model(templates: six + [Template(label: "play", frames: six[0].frames)], evaluate: evaluate)
        ready.onAppear()
        XCTAssertEqual(ready.readout, .testing)
        await ready.waitForReadout()
        XCTAssertEqual(ready.readout, .result(accuracy: 100, chance: 50, aboveChance: true))
        XCTAssertEqual(ready.readout.status, "Above chance")
        XCTAssertEqual(ready.readout.description, "Accuracy 100%, chance 50%")
        XCTAssertEqual(mainFlags.values, [false])
    }

    func testToggleOnWithUndeterminedCameraRequestsAccess() throws {
        let permission = FakeCameraPermission(.notDetermined)
        let model = try model(permission: permission)
        model.enabledChanged(false)
        XCTAssertEqual(permission.requests, 0)
        model.enabledChanged(true)
        XCTAssertEqual(permission.requests, 1)
        XCTAssertFalse(model.showsPermissionNote(enabled: true))

        permission.respond(granted: false)
        XCTAssertTrue(model.showsPermissionNote(enabled: true))
    }

    func testDeniedCameraShowsNoteOnlyWhenRelevant() throws {
        let denied = FakeCameraPermission(.denied)
        let model = try model(permission: denied)
        XCTAssertFalse(model.showsPermissionNote(enabled: false))
        XCTAssertTrue(model.showsPermissionNote(enabled: true))

        let granted = try self.model(permission: FakeCameraPermission(.granted))
        granted.enabledChanged(true)
        XCTAssertFalse(granted.showsPermissionNote(enabled: true))
    }

    func testGrantedToggleDoesNotPrompt() throws {
        let permission = FakeCameraPermission(.granted)
        let model = try model(permission: permission)
        model.enabledChanged(true)
        XCTAssertEqual(permission.requests, 0)
    }

    func testRecordWithoutCameraRequestsAndDoesNotStart() throws {
        let permission = FakeCameraPermission(.notDetermined)
        let model = try model(permission: permission)
        model.record("stop")
        XCTAssertEqual(permission.requests, 1)
        XCTAssertFalse(model.enrollment.isRecording)
        permission.respond(granted: false)
        XCTAssertFalse(model.enrollment.isRecording)
        XCTAssertTrue(model.showsPermissionNote(enabled: false))
    }

    func testDescriptions() {
        XCTAssertTrue(TrueWhisperSettingsModel.toggleDescription(isReady: false).hasSuffix("at least two words are enrolled below."))
        XCTAssertTrue(TrueWhisperSettingsModel.toggleDescription(isReady: true).hasSuffix("no video is stored."))
        XCTAssertTrue(TrueWhisperEnrollment.isReady(["stop": 3, "cancel": 10]))
        XCTAssertFalse(TrueWhisperEnrollment.isReady(["stop": 3, "cancel": 2, "play": 2]))
    }
}

final class TrueWhisperConfigTests: XCTestCase {
    func testTrueWhisperDefaultsOffAndRoundTrips() throws {
        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: configDir) }
        let manager = ConfigManager(configDir: configDir)

        XCTAssertFalse(SttConfig().true_whisper)
        var config = manager.load()
        XCTAssertFalse(config.stt.true_whisper)

        config.stt.true_whisper = true
        try manager.save(config)
        XCTAssertTrue(try String(contentsOf: manager.configPath, encoding: .utf8).contains("true_whisper = true"))
        XCTAssertTrue(manager.load().stt.true_whisper)

        config.stt.true_whisper = false
        try manager.save(config)
        XCTAssertFalse(manager.load().stt.true_whisper)

        // Missing key in an existing [stt] table keeps the default.
        try "[stt]\nmodel = \"parakeet-tdt-v2\"\n".write(to: manager.configPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(manager.load().stt.true_whisper)
    }

    func testTrueWhisperParticipatesInSettingsDraftChanges() {
        let saved = AppConfig()
        var draft = saved
        draft.stt.true_whisper = true
        XCTAssertNotEqual(draft, saved)
        draft.stt.true_whisper = false
        XCTAssertEqual(draft, saved)
    }
}

/// Stands in for the camera: emits frames only when the test pushes them.
private final class PushFrameSource: FrameSource {
    var onFrame: LipGeometryHandler?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let framesOnStart: Int
    private let startError: Error?
    private var t = 0.0

    init(framesOnStart: Int, startError: Error? = nil) {
        self.framesOnStart = framesOnStart
        self.startError = startError
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        push(framesOnStart)
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func push(_ count: Int) {
        guard isRunning else { return }
        for _ in 0..<count {
            t += 1.0 / 30
            onFrame?(t, TrueWhisperFixtures.rest)
        }
    }
}

private final class FakeCameraPermission: TrueWhisperCameraPermission {
    var camera: PermissionStatus
    private(set) var requests = 0
    private(set) var opened: [PermissionKind] = []
    private var pending: [(Bool) -> Void] = []

    init(_ status: PermissionStatus) { camera = status }

    func requestCameraPrompt(completion: @escaping (Bool) -> Void) {
        requests += 1
        pending.append(completion)
    }

    func respond(granted: Bool) {
        camera = granted ? .granted : .denied
        pending.forEach { $0(granted) }
        pending = []
    }

    func openSettings(for kind: PermissionKind) { opened.append(kind) }
}

private final class MainThreadFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    func record(_ isMain: Bool) { lock.lock(); flags.append(isMain); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return flags }
}
