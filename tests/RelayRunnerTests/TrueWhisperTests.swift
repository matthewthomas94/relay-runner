import AVFoundation
import CoreGraphics
import XCTest
@testable import relay_runner
@testable import TrueWhisper

final class TrueWhisperGeometryTests: XCTestCase {
    func testSyntheticLandmarksGiveExpectedChannels() throws {
        // Eyes 10 apart, so lengths divide by 10 and areas by 100.
        let leftEye = [CGPoint(x: -6, y: 0), CGPoint(x: -4, y: 0)]   // centre (-5, 0)
        let rightEye = [CGPoint(x: 4, y: 0), CGPoint(x: 6, y: 0)]    // centre (5, 0)
        let outer = [CGPoint(x: -4, y: -12), CGPoint(x: 4, y: -12),
                     CGPoint(x: 4, y: -8), CGPoint(x: -4, y: -8)]    // 8 x 4 rectangle
        let inner = [CGPoint(x: -2, y: -11), CGPoint(x: 2, y: -11),
                     CGPoint(x: 2, y: -9), CGPoint(x: -2, y: -9)]    // 4 x 2 rectangle
        let contour = [CGPoint(x: -8, y: -5), CGPoint(x: 0, y: -15), CGPoint(x: 8, y: -5)]

        let g = try XCTUnwrap(LipGeometry.frame(outerLips: outer, innerLips: inner,
                                                leftEye: leftEye, rightEye: rightEye, faceContour: contour))
        let expected = [0.8, 0.4, 0.2, 0.32, 0.08, 1.5]
        XCTAssertEqual(g.count, 6)
        for (value, want) in zip(g, expected) { XCTAssertEqual(value, want, accuracy: 1e-12) }
    }

    func testMissingRegionsOrCoincidentEyesGiveNil() {
        let tri = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        XCTAssertNil(LipGeometry.frame(outerLips: tri, innerLips: tri, leftEye: [], rightEye: tri, faceContour: tri))
        XCTAssertNil(LipGeometry.frame(outerLips: tri, innerLips: tri, leftEye: [.zero], rightEye: [.zero], faceContour: tri))
    }
}

final class TrueWhisperClassifierTests: XCTestCase {
    func testDTWOfSequenceToItselfIsZeroAndToStretchedCopyIsSmall() {
        let seq = TrueWhisperFixtures.word(phase: 0, frames: 30)
        XCTAssertEqual(DTW.distance(seq, seq), 0)

        // 1.5x slower: every frame of the original, some repeated.
        let stretched = (0..<45).map { seq[$0 * 30 / 45] }
        let other = TrueWhisperFixtures.word(phase: .pi / 2, frames: 30)
        let near = DTW.distance(seq, stretched)
        XCTAssertLessThan(near, 0.05)
        XCTAssertLessThan(near, DTW.distance(seq, other))
    }

    func testClassifierRanksNoisyCopyOfTemplateAsItsOwnLabel() throws {
        let templates = TrueWhisperFixtures.templates(perLabel: 3)
        let clf = try XCTUnwrap(TemplateClassifier(templates: templates))
        XCTAssertEqual(clf.labels, ["cancel", "stop"])

        var rng = TrueWhisperFixtures.SeededGenerator(seed: 99)
        for t in templates {
            let noisy = TrueWhisperFixtures.jitter(t.frames, amount: 0.005, using: &rng)
            XCTAssertEqual(clf.rank(noisy).first?.label, t.label)
        }
    }

    func testEvaluationSeparatesClearlyDistinctLabels() throws {
        let ev = try XCTUnwrap(Evaluation.run(templates: TrueWhisperFixtures.templates(perLabel: 6), permutations: 200))
        XCTAssertEqual(ev.accuracy, 1.0)
        XCTAssertLessThan(ev.pValue, 0.05)
        XCTAssertEqual(ev.labels, ["cancel", "stop"])
        XCTAssertEqual(ev.confusion, [[6, 0], [0, 6]])
    }

    func testEvaluationNeedsTwoLabelsWithTwoTakes() {
        let one = TrueWhisperFixtures.templates(perLabel: 1)
        XCTAssertNil(Evaluation.run(templates: one, permutations: 10))
    }
}

final class TrueWhisperSegmenterTests: XCTestCase {
    func testOneSegmentForABurstOfMotionAfterCalibration() {
        let seg = Segmenter()
        var segments: [[[Double]]] = []
        seg.onSegment = { segments.append($0) }

        let source = InjectedFrameSource(frames: TrueWhisperFixtures.stillThenBurst())
        source.onFrame = { t, g in
            seg.ingest(t: t, g: g)
            if !seg.isCalibrating, !seg.autoEnabled { seg.autoEnabled = true }
        }
        seg.calibrate()
        XCTAssertNoThrow(try source.start())

        XCTAssertNotNil(seg.noiseFloor)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThanOrEqual(segments.first?.count ?? 0, 15)
        XCTAssertFalse(seg.isCapturing)
    }
}

final class TrueWhisperTemplateStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TemplateStore(url: dir.appendingPathComponent("nested/templates.json"))

        XCTAssertEqual(store.load(), [])
        let templates = TrueWhisperFixtures.templates(perLabel: 2)
        try store.save(templates)
        XCTAssertEqual(store.load(), templates)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [[String: Any]]
        XCTAssertEqual(Set(json?.first?.keys.map { $0 } ?? []), ["label", "frames"])
    }

    func testDefaultLocation() {
        XCTAssertTrue(TemplateStore.defaultURL.path.hasSuffix(
            "Library/Application Support/relay-runner/true-whisper/templates.json"))
    }
}

final class TrueWhisperCaptureSessionTests: XCTestCase {
    func testStartWithoutCameraPermissionThrowsAndHoldsNoDevice() {
        let session = LipCaptureSession(authorizationStatus: { .denied })
        XCTAssertThrowsError(try session.start()) { XCTAssertEqual($0 as? LipCaptureError, .notAuthorized) }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.captureSession.inputs.isEmpty)
    }

    func testStopTearsDownAndIsIdempotent() {
        let session = LipCaptureSession(authorizationStatus: { .denied })
        session.stop()
        session.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.captureSession.isRunning)
        XCTAssertTrue(session.captureSession.inputs.isEmpty)
        XCTAssertTrue(session.captureSession.outputs.isEmpty)
    }
}

final class TrueWhisperCameraPermissionTests: XCTestCase {
    func testCameraStatusMapping() {
        XCTAssertEqual(PermissionsManager.cameraStatus(for: .authorized), .granted)
        XCTAssertEqual(PermissionsManager.cameraStatus(for: .denied), .denied)
        XCTAssertEqual(PermissionsManager.cameraStatus(for: .restricted), .restricted)
        XCTAssertEqual(PermissionsManager.cameraStatus(for: .notDetermined), .notDetermined)
    }

    func testCameraKindIsOptInOnly() {
        XCTAssertEqual(PermissionKind.camera.displayName, "Camera")
        XCTAssertFalse(PermissionKind.guidedSetupOrder.contains(.camera))
        XCTAssertFalse(PermissionKind.camera.opensSystemSettingsDuringSetup)
        XCTAssertTrue(PermissionKind.camera.settingsURL.hasSuffix("Privacy_Camera"))
    }
}

/// Replays recorded geometry frames synchronously, standing in for the camera.
private final class InjectedFrameSource: FrameSource {
    var onFrame: LipGeometryHandler?
    private(set) var isRunning = false
    private let frames: [(t: Double, g: [Double])]

    init(frames: [(t: Double, g: [Double])]) { self.frames = frames }

    func start() throws {
        isRunning = true
        for f in frames where isRunning { onFrame?(f.t, f.g) }
        isRunning = false
    }

    func stop() { isRunning = false }
}

enum TrueWhisperFixtures {
    static let rest = [0.8, 0.1, 0.02, 0.06, 0.01, 1.5]

    /// A word-like movement: still, then one articulation, then still.
    /// `phase` changes which channels move together, so different phases are
    /// different "words".
    static func word(phase: Double, frames: Int) -> [[Double]] {
        (0..<frames).map { i in
            let x = Double(i) / Double(frames - 1)
            let envelope = sin(.pi * x) * sin(.pi * x)
            return rest.enumerated().map { k, base in
                base + 0.1 * envelope * sin(2 * .pi * x + phase + Double(k) * phase)
            }
        }
    }

    static func templates(perLabel: Int) -> [Template] {
        var rng = SeededGenerator(seed: 7)
        return (0..<perLabel).flatMap { k -> [Template] in
            [
                Template(label: "stop", frames: jitter(word(phase: 0, frames: 28 + k), amount: 0.002, using: &rng)),
                Template(label: "cancel", frames: jitter(word(phase: 2.2, frames: 30 + k), amount: 0.002, using: &rng)),
            ]
        }
    }

    static func jitter(_ frames: [[Double]], amount: Double, using rng: inout SeededGenerator) -> [[Double]] {
        frames.map { row in row.map { $0 + Double.random(in: -amount...amount, using: &rng) } }
    }

    /// 30 fps: 3 s still (2 s calibration plus margin), 0.6 s of motion, 1 s still.
    static func stillThenBurst() -> [(t: Double, g: [Double])] {
        var rng = SeededGenerator(seed: 3)
        let still = { (n: Int) in (0..<n).map { _ in rest.map { $0 + Double.random(in: -0.0005...0.0005, using: &rng) } } }
        let frames = still(90) + word(phase: 0, frames: 18) + still(30)
        return frames.enumerated().map { (Double($0.offset) / 30, $0.element) }
    }

    /// Deterministic generator so fixtures do not flake.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
