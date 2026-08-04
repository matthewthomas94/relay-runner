import AVFAudio
import CoreAudio
import Foundation

struct AudioInputRoute: Equatable, Sendable {
    let deviceID: AudioObjectID
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
}

enum AudioCaptureFailure: LocalizedError, Equatable {
    case noInput
    case incompatibleFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    case converterUnavailable(sampleRate: Double, channelCount: AVAudioChannelCount)
    case coreAudio(OSStatus)
    case engineStart(String)

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No microphone input is currently available. Relay Runner will recover when one returns."
        case .incompatibleFormat(let sampleRate, let channelCount):
            return "The microphone format is unavailable (\(sampleRate) Hz, \(channelCount) channels)."
        case .converterUnavailable(let sampleRate, let channelCount):
            return "The microphone format cannot be converted to 16 kHz mono (\(sampleRate) Hz, \(channelCount) channels)."
        case .coreAudio(let status):
            return "Core Audio could not monitor the system-default microphone (status \(status))."
        case .engineStart(let message):
            return "The microphone capture graph could not start: \(message)"
        }
    }
}

protocol AudioCaptureBackend: AnyObject {
    var onConfigurationChange: ((String) -> Void)? { get set }
    func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute
    func stop()
}

protocol DefaultAudioInputMonitoring: AnyObject {
    var onDefaultInputChanged: (() -> Void)? { get set }
    func start() throws
    func stop()
}

struct AudioCaptureInterruption: Equatable, Sendable {
    enum RecordingOutcome: Equatable, Sendable {
        case idle
        case cancelRecording
    }

    let reasons: Set<String>
    let recordingOutcome: RecordingOutcome
}

struct AudioCaptureRecovery: Equatable, Sendable {
    let previousRoute: AudioInputRoute?
    let route: AudioInputRoute?
    let reasons: Set<String>
    let error: AudioCaptureFailure?
}

/// Owns every mutation of the live capture graph on one serial queue. Default-input
/// and AVAudioEngine notifications only request a coalesced rebuild; they never
/// install or remove taps directly.
final class AudioCaptureLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.relayrunner.audio-capture-lifecycle")
    private let backend: AudioCaptureBackend
    private let routeMonitor: DefaultAudioInputMonitoring
    private let recoveryDelay: TimeInterval
    private let sampleHandler: ([Float]) -> Void
    private let isRecording: () -> Bool

    private var running = false
    private var currentRoute: AudioInputRoute?
    private var recoveryWorkItem: DispatchWorkItem?
    private var pendingReasons: Set<String> = []

    var onWillReconfigure: ((AudioCaptureInterruption) -> Void)?
    var onRecovery: ((AudioCaptureRecovery) -> Void)?

    init(
        backend: AudioCaptureBackend = SystemDefaultAudioCaptureBackend(),
        routeMonitor: DefaultAudioInputMonitoring = CoreAudioDefaultInputMonitor(),
        recoveryDelay: TimeInterval = 0.2,
        sampleHandler: @escaping ([Float]) -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.backend = backend
        self.routeMonitor = routeMonitor
        self.recoveryDelay = recoveryDelay
        self.sampleHandler = sampleHandler
        self.isRecording = isRecording

        backend.onConfigurationChange = { [weak self] reason in
            self?.requestRecovery(reason: reason)
        }
        routeMonitor.onDefaultInputChanged = { [weak self] in
            self?.requestRecovery(reason: "system-default-input")
        }
    }

    func start() throws -> AudioInputRoute? {
        try queue.sync {
            guard !running else {
                return currentRoute
            }

            running = true
            do {
                try routeMonitor.start()
            } catch {
                running = false
                throw error
            }

            do {
                let route = try backend.start(sampleHandler: sampleHandler)
                currentRoute = route
                return route
            } catch let error as AudioCaptureFailure {
                backend.stop()
                currentRoute = nil
                onRecovery?(AudioCaptureRecovery(
                    previousRoute: nil,
                    route: nil,
                    reasons: ["initial-start"],
                    error: error
                ))
                return nil
            } catch {
                backend.stop()
                routeMonitor.stop()
                running = false
                throw error
            }
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            recoveryWorkItem?.cancel()
            recoveryWorkItem = nil
            pendingReasons.removeAll()
            routeMonitor.stop()
            backend.stop()
            currentRoute = nil
        }
    }

    private func requestRecovery(reason: String) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.pendingReasons.insert(reason)
            guard self.recoveryWorkItem == nil else { return }

            let outcome: AudioCaptureInterruption.RecordingOutcome =
                self.isRecording() ? .cancelRecording : .idle
            self.onWillReconfigure?(AudioCaptureInterruption(
                reasons: self.pendingReasons,
                recordingOutcome: outcome
            ))

            let workItem = DispatchWorkItem { [weak self] in
                self?.performPendingRecovery()
            }
            self.recoveryWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + self.recoveryDelay, execute: workItem)
        }
    }

    private func performPendingRecovery() {
        guard running else {
            recoveryWorkItem = nil
            pendingReasons.removeAll()
            return
        }

        recoveryWorkItem = nil
        let reasons = pendingReasons
        pendingReasons.removeAll()
        let previousRoute = currentRoute
        backend.stop()

        do {
            let route = try backend.start(sampleHandler: sampleHandler)
            currentRoute = route
            onRecovery?(AudioCaptureRecovery(
                previousRoute: previousRoute,
                route: route,
                reasons: reasons,
                error: nil
            ))
        } catch let error as AudioCaptureFailure {
            currentRoute = nil
            onRecovery?(AudioCaptureRecovery(
                previousRoute: previousRoute,
                route: nil,
                reasons: reasons,
                error: error
            ))
        } catch {
            currentRoute = nil
            onRecovery?(AudioCaptureRecovery(
                previousRoute: previousRoute,
                route: nil,
                reasons: reasons,
                error: .engineStart(error.localizedDescription)
            ))
        }
    }

    /// Deterministic seam for focused lifecycle tests. Production recovery uses
    /// the bounded delay above so duplicate system notifications collapse.
    func performPendingRecoveryForTesting() {
        queue.sync {
            guard recoveryWorkItem != nil else { return }
            recoveryWorkItem?.cancel()
            performPendingRecovery()
        }
    }
}

final class SystemDefaultAudioCaptureBackend: AudioCaptureBackend {
    var onConfigurationChange: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let runtimeFailureLock = NSLock()
    private var reportedRuntimeFailure = false

    func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
        stop()

        let deviceID = try Self.defaultInputDeviceID()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw AudioCaptureFailure.incompatibleFormat(
                sampleRate: nativeFormat.sampleRate,
                channelCount: nativeFormat.channelCount
            )
        }
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ), let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw AudioCaptureFailure.converterUnavailable(
                sampleRate: nativeFormat.sampleRate,
                channelCount: nativeFormat.channelCount
            )
        }

        runtimeFailureLock.withLock { reportedRuntimeFailure = false }
        inputNode.installTap(onBus: 0, bufferSize: 8_000, format: nativeFormat) {
            [weak self] buffer, _ in
            let ratio = 16_000.0 / nativeFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCount
                  )
            else { return }

            var conversionError: NSError?
            var consumed = false
            converter.convert(to: converted, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }

            if let conversionError {
                let shouldReport = self?.runtimeFailureLock.withLock {
                    guard self?.reportedRuntimeFailure == false else { return false }
                    self?.reportedRuntimeFailure = true
                    return true
                } ?? false
                if shouldReport {
                    NSLog("[STTEngine] Audio conversion failed; scheduling recovery: \(conversionError)")
                    self?.onConfigurationChange?("conversion-failure")
                }
                return
            }

            guard let channelData = converted.floatChannelData else { return }
            sampleHandler(Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(converted.frameLength)
            )))
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureFailure.engineStart(error.localizedDescription)
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?("engine-configuration")
        }

        return AudioInputRoute(
            deviceID: deviceID,
            sampleRate: nativeFormat.sampleRate,
            channelCount: nativeFormat.channelCount
        )
    }

    func stop() {
        removeConfigurationObserver()
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private static func defaultInputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { throw AudioCaptureFailure.coreAudio(status) }
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureFailure.noInput
        }
        return deviceID
    }
}

final class CoreAudioDefaultInputMonitor: DefaultAudioInputMonitoring {
    var onDefaultInputChanged: (() -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.relayrunner.default-input-monitor")
    private var listener: AudioObjectPropertyListenerBlock?

    func start() throws {
        guard listener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultInputChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        guard status == noErr else { throw AudioCaptureFailure.coreAudio(status) }
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        self.listener = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
