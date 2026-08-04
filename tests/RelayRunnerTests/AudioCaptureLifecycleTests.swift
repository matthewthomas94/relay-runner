import AVFAudio
import XCTest
@testable import relay_runner

final class AudioCaptureLifecycleTests: XCTestCase {
    private let routeA = AudioInputRoute(deviceID: 101, sampleRate: 44_100, channelCount: 1)
    private let routeB = AudioInputRoute(deviceID: 202, sampleRate: 48_000, channelCount: 2)

    func testIdleDefaultInputSwitchRebuildsCaptureOnNewRoute() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var interruptions: [AudioCaptureInterruption] = []
        var recoveries: [AudioCaptureRecovery] = []
        lifecycle.onWillReconfigure = { interruptions.append($0) }
        lifecycle.onRecovery = { recoveries.append($0) }

        XCTAssertEqual(try lifecycle.start(), routeA)
        monitor.emitChange()
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(backend.startCount, 2)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(interruptions.map(\.recordingOutcome), [.idle])
        XCTAssertEqual(recoveries.last?.previousRoute, routeA)
        XCTAssertEqual(recoveries.last?.route, routeB)
    }

    func testDuplicateDefaultAndEngineNotificationsCoalesceIntoOneRecovery() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var interruptionCount = 0
        var recoveryCount = 0
        lifecycle.onWillReconfigure = { _ in interruptionCount += 1 }
        lifecycle.onRecovery = { _ in recoveryCount += 1 }

        _ = try lifecycle.start()
        monitor.emitChange()
        monitor.emitChange()
        backend.emitConfigurationChange(reason: "engine-configuration")
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(backend.startCount, 2)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testActiveRecordingSwitchRequestsExactlyOneCancellation() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        var isRecording = true
        let lifecycle = makeLifecycle(
            backend: backend,
            monitor: monitor,
            isRecording: { isRecording }
        )
        var outcomes: [AudioCaptureInterruption.RecordingOutcome] = []
        lifecycle.onWillReconfigure = { outcomes.append($0.recordingOutcome) }

        _ = try lifecycle.start()
        monitor.emitChange()
        backend.emitConfigurationChange(reason: "engine-configuration")
        lifecycle.performPendingRecoveryForTesting()
        isRecording = false

        XCTAssertEqual(outcomes, [.cancelRecording])
        XCTAssertEqual(backend.startCount, 2)
    }

    func testFormatChangePublishesNewSampleRateAndChannelCount() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var recoveredRoute: AudioInputRoute?
        lifecycle.onRecovery = { recoveredRoute = $0.route }

        _ = try lifecycle.start()
        backend.emitConfigurationChange(reason: "engine-configuration")
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(recoveredRoute?.sampleRate, 48_000)
        XCTAssertEqual(recoveredRoute?.channelCount, 2)
    }

    func testUnplugAndReconnectRecoversAfterTemporaryNoInput() throws {
        let backend = FakeAudioCaptureBackend(results: [
            .success(routeA),
            .failure(AudioCaptureFailure.noInput),
            .success(routeB),
        ])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var recoveries: [AudioCaptureRecovery] = []
        lifecycle.onRecovery = { recoveries.append($0) }

        _ = try lifecycle.start()
        monitor.emitChange()
        lifecycle.performPendingRecoveryForTesting()
        XCTAssertEqual(recoveries.last?.error, .noInput)

        monitor.emitChange()
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(recoveries.last?.route, routeB)
        XCTAssertNil(recoveries.last?.error)
        XCTAssertEqual(backend.startCount, 3)
    }

    func testInitialNoInputWaitsForDefaultDeviceToReturn() throws {
        let backend = FakeAudioCaptureBackend(results: [
            .failure(AudioCaptureFailure.noInput),
            .success(routeB),
        ])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var recoveries: [AudioCaptureRecovery] = []
        lifecycle.onRecovery = { recoveries.append($0) }

        XCTAssertNil(try lifecycle.start())
        XCTAssertEqual(recoveries.last?.error, .noInput)

        monitor.emitChange()
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(recoveries.last?.route, routeB)
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testSettingsRestartCancelsPendingRecoveryAndStartsFreshGraph() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)

        _ = try lifecycle.start()
        monitor.emitChange()
        lifecycle.stop()
        XCTAssertEqual(try lifecycle.start(), routeB)
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(backend.startCount, 2)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(monitor.startCount, 2)
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testLateNotificationsCannotRestartStoppedCapture() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)

        _ = try lifecycle.start()
        monitor.emitChange()
        lifecycle.stop()
        monitor.emitChange()
        backend.emitConfigurationChange(reason: "engine-configuration")
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(monitor.stopCount, 1)
    }

    private func makeLifecycle(
        backend: FakeAudioCaptureBackend,
        monitor: FakeDefaultAudioInputMonitor,
        isRecording: @escaping () -> Bool = { false }
    ) -> AudioCaptureLifecycle {
        AudioCaptureLifecycle(
            backend: backend,
            routeMonitor: monitor,
            recoveryDelay: 60,
            sampleHandler: { _ in },
            isRecording: isRecording
        )
    }
}

private final class FakeAudioCaptureBackend: AudioCaptureBackend {
    var onConfigurationChange: ((String) -> Void)?
    private var results: [Result<AudioInputRoute, Error>]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(results: [Result<AudioInputRoute, Error>]) {
        self.results = results
    }

    func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
        startCount += 1
        guard !results.isEmpty else { throw AudioCaptureFailure.noInput }
        return try results.removeFirst().get()
    }

    func stop() {
        stopCount += 1
    }

    func emitConfigurationChange(reason: String) {
        onConfigurationChange?(reason)
    }
}

private final class FakeDefaultAudioInputMonitor: DefaultAudioInputMonitoring {
    var onDefaultInputChanged: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emitChange() {
        onDefaultInputChanged?()
    }
}
