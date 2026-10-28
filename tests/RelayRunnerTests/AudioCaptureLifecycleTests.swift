import AVFAudio
import CoreAudio
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

    func testDefaultInputNotificationNamingTheCapturedDeviceIsIgnored() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let monitor = FakeDefaultAudioInputMonitor()
        let lifecycle = makeLifecycle(backend: backend, monitor: monitor)
        var interruptionCount = 0
        lifecycle.onWillReconfigure = { _ in interruptionCount += 1 }

        _ = try lifecycle.start()
        monitor.emitChange(to: routeA.deviceID)
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(interruptionCount, 0)
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 0)

        monitor.emitChange(to: routeB.deviceID)
        lifecycle.performPendingRecoveryForTesting()

        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(backend.startCount, 2)
    }

    func testRecoveryDeadlineWaitsForQuietButCapsTheBurst() {
        let burstStart = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        func deadline(atChange seconds: Double) -> Double {
            let deadline = AudioCaptureLifecycle.recoveryDeadline(
                now: burstStart + seconds,
                burstStart: burstStart,
                delay: 0.5
            )
            return Double(deadline.uptimeNanoseconds - burstStart.uptimeNanoseconds) / 1e9
        }

        XCTAssertEqual(deadline(atChange: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(deadline(atChange: 0.4), 0.9, accuracy: 1e-6)
        XCTAssertEqual(deadline(atChange: 1.2), 1.5, accuracy: 1e-6)
    }

    func testChangeDuringTheDebounceDefersASingleRebuild() throws {
        let backend = FakeAudioCaptureBackend(results: [.success(routeA), .success(routeB)])
        let lifecycle = AudioCaptureLifecycle(
            backend: backend,
            routeMonitor: FakeDefaultAudioInputMonitor(),
            recoveryDelay: 1,
            sampleHandler: { _ in },
            isRecording: { false }
        )
        let recovered = expectation(description: "recovered")
        var recoveredAt: DispatchTime?
        lifecycle.onRecovery = { _ in
            recoveredAt = .now()
            recovered.fulfill()
        }

        _ = try lifecycle.start()
        let firstChange = DispatchTime.now()
        backend.emitConfigurationChange(reason: "engine-configuration")
        Thread.sleep(forTimeInterval: 0.4)
        backend.emitConfigurationChange(reason: "engine-configuration")
        wait(for: [recovered], timeout: 5)

        XCTAssertEqual(backend.startCount, 2)
        let elapsed = Double(recoveredAt!.uptimeNanoseconds - firstChange.uptimeNanoseconds) / 1e9
        XCTAssertGreaterThanOrEqual(elapsed, 1.35)
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
    var onDefaultInputChanged: ((AudioObjectID?) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emitChange(to deviceID: AudioObjectID? = nil) {
        onDefaultInputChanged?(deviceID)
    }
}
