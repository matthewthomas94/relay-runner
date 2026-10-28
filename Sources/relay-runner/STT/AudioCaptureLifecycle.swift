import AVFAudio
import AudioToolbox
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
    /// Receives the new system-default input, or nil when it cannot be read.
    var onDefaultInputChanged: ((AudioObjectID?) -> Void)? { get set }
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
/// and captured-device notifications only request a debounced rebuild; they never
/// start or stop capture directly.
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
    private var recoveryBurstStart = DispatchTime.now()
    private var pendingReasons: Set<String> = []

    var onWillReconfigure: ((AudioCaptureInterruption) -> Void)?
    var onRecovery: ((AudioCaptureRecovery) -> Void)?

    init(
        backend: AudioCaptureBackend = SystemDefaultAudioCaptureBackend(),
        routeMonitor: DefaultAudioInputMonitoring = CoreAudioDefaultInputMonitor(),
        recoveryDelay: TimeInterval = 0.5,
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
        routeMonitor.onDefaultInputChanged = { [weak self] deviceID in
            self?.requestRecovery(reason: "system-default-input", defaultInput: deviceID)
        }
    }

    /// Recovery waits until route changes have been quiet for `delay`, but never
    /// more than three delays after the burst's first change, so a flapping route
    /// cannot hold capture down.
    static func recoveryDeadline(
        now: DispatchTime,
        burstStart: DispatchTime,
        delay: TimeInterval
    ) -> DispatchTime {
        min(now + delay, burstStart + delay * 3)
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

    private func requestRecovery(reason: String, defaultInput: AudioObjectID? = nil) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            // A default-input notification that still names the captured device
            // does not affect capture.
            if let defaultInput, defaultInput == self.currentRoute?.deviceID { return }
            self.pendingReasons.insert(reason)

            let now = DispatchTime.now()
            if let pending = self.recoveryWorkItem {
                pending.cancel()
            } else {
                self.recoveryBurstStart = now
                let outcome: AudioCaptureInterruption.RecordingOutcome =
                    self.isRecording() ? .cancelRecording : .idle
                self.onWillReconfigure?(AudioCaptureInterruption(
                    reasons: self.pendingReasons,
                    recordingOutcome: outcome
                ))
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.performPendingRecovery()
            }
            self.recoveryWorkItem = workItem
            self.queue.asyncAfter(
                deadline: Self.recoveryDeadline(
                    now: now,
                    burstStart: self.recoveryBurstStart,
                    delay: self.recoveryDelay
                ),
                execute: workItem
            )
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

/// Captures the system-default input through an input-only AUHAL bound to that
/// device. AVAudioEngine always runs the default output device in a private
/// aggregate, so every engine start and stop powered the speaker amplifier;
/// this unit never enables output.
final class SystemDefaultAudioCaptureBackend: AudioCaptureBackend {
    /// Native-rate frames per delivered chunk, matching the former engine tap.
    static let chunkFrames: AVAudioFrameCount = 8_000
    /// Render scratch per IO cycle. HAL devices do not run larger IO buffers; a
    /// larger cycle is dropped rather than overrun.
    private static let maximumIOFrames: UInt32 = 16_384

    var onConfigurationChange: ((String) -> Void)?

    private let deviceListenerQueue = DispatchQueue(label: "com.relayrunner.captured-input-monitor")
    private var unit: AudioUnit?
    private var renderer: HALInputRenderer?
    private var ring: CaptureChunkRing?
    private var deviceWatch: CapturedDeviceWatch?

    func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
        stop()

        let deviceID = try systemDefaultInputDeviceID()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureFailure.engineStart("The input audio unit is unavailable.")
        }
        try Self.check(AudioComponentInstanceNew(component, &instance), "create the input unit")
        guard let unit = instance else {
            throw AudioCaptureFailure.engineStart("The input audio unit is unavailable.")
        }
        self.unit = unit

        do {
            return try startCapture(on: unit, deviceID: deviceID, sampleHandler: sampleHandler)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        deviceWatch?.cancel()
        deviceWatch = nil
        if let unit {
            // Synchronous: the IO thread no longer calls the renderer afterwards.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        ring?.stop()
        ring = nil
        renderer = nil
    }

    private func startCapture(
        on unit: AudioUnit,
        deviceID: AudioObjectID,
        sampleHandler: @escaping ([Float]) -> Void
    ) throws -> AudioInputRoute {
        // TN2091 order: enable input and disable output before binding the device.
        try Self.setProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable input"
        )
        try Self.setProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable output"
        )
        try Self.setProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID,
            "select the input device"
        )

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size
            ),
            "read the input format"
        )
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0,
              let nativeFormat = AVAudioFormat(
                standardFormatWithSampleRate: deviceFormat.mSampleRate,
                channels: deviceFormat.mChannelsPerFrame
              ),
              let ring = CaptureChunkRing(format: nativeFormat, chunkFrames: Self.chunkFrames)
        else {
            throw AudioCaptureFailure.incompatibleFormat(
                sampleRate: deviceFormat.mSampleRate,
                channelCount: deviceFormat.mChannelsPerFrame
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

        // The unit converts sample format but not rate, so capture at the device
        // rate and resample to 16 kHz on the delivery thread.
        try Self.setProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            nativeFormat.streamDescription.pointee, "set the capture format"
        )
        try Self.setProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            Self.maximumIOFrames, "size the input buffers"
        )
        let renderer = HALInputRenderer(unit: unit, ring: ring, maximumFrames: Self.maximumIOFrames)
        self.renderer = renderer
        self.ring = ring
        try Self.setProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            AURenderCallbackStruct(
                inputProc: renderCapturedInput,
                inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque()
            ),
            "install the input callback"
        )
        try Self.check(AudioUnitInitialize(unit), "initialize the input unit")

        var reportedConversionFailure = false
        ring.start { [weak self] buffer in
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
                if !reportedConversionFailure {
                    reportedConversionFailure = true
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
        deviceWatch = CapturedDeviceWatch(deviceID: deviceID, queue: deviceListenerQueue) { [weak self] in
            self?.onConfigurationChange?("engine-configuration")
        }
        try Self.check(AudioOutputUnitStart(unit), "start the input unit")

        return AudioInputRoute(
            deviceID: deviceID,
            sampleRate: nativeFormat.sampleRate,
            channelCount: nativeFormat.channelCount
        )
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw AudioCaptureFailure.engineStart("Could not \(action) (status \(status)).")
        }
    }

    private static func setProperty<Value>(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ value: Value,
        _ action: String
    ) throws {
        let status = withUnsafePointer(to: value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<Value>.size))
        }
        try check(status, action)
    }
}

/// HAL IO thread entry point for `HALInputRenderer`.
private func renderCapturedInput(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frameCount: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<HALInputRenderer>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
}

/// Real-time half of the capture backend: pulls each IO cycle into
/// preallocated memory and hands it to the ring. Nothing here allocates, locks
/// or runs the sample handler.
private final class HALInputRenderer {
    private let unit: AudioUnit
    private let ring: CaptureChunkRing
    private let maximumFrames: UInt32
    private let buffers: UnsafeMutableAudioBufferListPointer

    init(unit: AudioUnit, ring: CaptureChunkRing, maximumFrames: UInt32) {
        self.unit = unit
        self.ring = ring
        self.maximumFrames = maximumFrames
        buffers = AudioBufferList.allocate(maximumBuffers: Int(ring.format.channelCount))
        let byteCount = Int(maximumFrames) * MemoryLayout<Float>.size
        for index in 0..<buffers.count {
            buffers[index].mNumberChannels = 1
            buffers[index].mDataByteSize = UInt32(byteCount)
            buffers[index].mData = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: MemoryLayout<Float>.alignment
            )
        }
    }

    deinit {
        for buffer in buffers {
            buffer.mData?.deallocate()
        }
        free(buffers.unsafeMutablePointer)
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= maximumFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        for index in 0..<buffers.count {
            buffers[index].mDataByteSize = byteSize
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, buffers.unsafeMutablePointer)
        guard status == noErr else { return status }
        ring.write(buffers, frameCount: Int(frameCount))
        return noErr
    }
}

/// Bounded single-producer/single-consumer handoff of fixed-size native-rate
/// chunks from the HAL IO thread to a delivery thread. The IO side only copies
/// into preallocated slots and signals semaphores; conversion and the sample
/// handler run on the delivery thread, as TN2091 recommends for resampling.
final class CaptureChunkRing: @unchecked Sendable {
    let format: AVAudioFormat
    private let chunkFrames: Int
    private let channelCount: Int
    private let slotCount: Int
    private let slots: [AVAudioPCMBuffer]
    /// Channel pointers for every slot, indexed `slot * channelCount + channel`,
    /// so the IO thread never touches the Objective-C buffers.
    private let channelData: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let filled = DispatchSemaphore(value: 0)
    private let vacant = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stopLock = NSLock()
    private var stopping = false
    private var thread: Thread?

    // IO thread only.
    private var writeSlot = 0
    private var writeFrame = 0
    private var holdsSlot = false
    // Delivery thread only.
    private var readSlot = 0

    init?(format: AVAudioFormat, chunkFrames: AVAudioFrameCount, slotCount: Int = 4) {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              chunkFrames > 0, slotCount > 0
        else { return nil }
        var slots: [AVAudioPCMBuffer] = []
        for _ in 0..<slotCount {
            guard let slot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  slot.floatChannelData != nil
            else { return nil }
            slot.frameLength = chunkFrames
            slots.append(slot)
        }
        let channelCount = Int(format.channelCount)
        let channelData = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(
            capacity: slotCount * channelCount
        )
        for (slotIndex, slot) in slots.enumerated() {
            for channel in 0..<channelCount {
                (channelData + slotIndex * channelCount + channel)
                    .initialize(to: slot.floatChannelData![channel])
            }
        }
        self.format = format
        self.chunkFrames = Int(chunkFrames)
        self.channelCount = channelCount
        self.slotCount = slotCount
        self.slots = slots
        self.channelData = channelData

        // Create both semaphores' kernel objects here rather than on the IO
        // thread at the first contended signal or overflow.
        _ = filled.wait(timeout: .now())
        _ = vacant.wait(timeout: .now())
        for _ in 0..<slotCount {
            vacant.signal()
        }
    }

    deinit {
        channelData.deallocate()
    }

    /// Starts the delivery thread. `deliver` receives each full chunk in order
    /// and must be done with it when it returns.
    func start(deliver: @escaping (AVAudioPCMBuffer) -> Void) {
        guard thread == nil else { return }
        let thread = Thread { [self] in
            while true {
                filled.wait()
                if stopLock.withLock({ stopping }) { break }
                deliver(slots[readSlot])
                readSlot = (readSlot + 1) % slotCount
                vacant.signal()
            }
            finished.signal()
        }
        thread.name = "com.relayrunner.audio-capture-delivery"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// IO thread. Copies deinterleaved frames into the current slot and
    /// publishes each slot as it fills. Frames are dropped while the delivery
    /// thread is a whole ring behind.
    func write(_ input: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let inputChannels = min(channelCount, input.count)
        var offset = 0
        while offset < frameCount {
            if !holdsSlot {
                guard vacant.wait(timeout: .now()) == .success else { return }
                holdsSlot = true
            }
            let count = min(frameCount - offset, chunkFrames - writeFrame)
            for channel in 0..<inputChannels {
                guard let source = input[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                (channelData[writeSlot * channelCount + channel] + writeFrame)
                    .update(from: source + offset, count: count)
            }
            writeFrame += count
            offset += count
            if writeFrame == chunkFrames {
                writeFrame = 0
                writeSlot = (writeSlot + 1) % slotCount
                holdsSlot = false
                filled.signal()
            }
        }
    }

    /// Stops delivery and waits for the delivery thread to exit, dropping any
    /// partial or undelivered chunk. Call only once the IO thread can no longer
    /// write.
    func stop() {
        guard thread != nil else { return }
        stopLock.withLock { stopping = true }
        filled.signal()
        finished.wait()
        thread = nil
    }
}

/// Watches only the captured device, so output-device changes never restart
/// capture, and ignores notifications that leave it alive with the same rate
/// and channel count. Nothing is reported after `cancel()` returns.
private final class CapturedDeviceWatch {
    private static let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    private let deviceID: AudioObjectID
    private let queue: DispatchQueue
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []
    private var isActive = true // `queue` only

    init(deviceID: AudioObjectID, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.deviceID = deviceID
        self.queue = queue
        let format = CapturedInputFormat(deviceID)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isActive, CapturedInputFormat(deviceID) != format else { return }
            onChange()
        }
        for (selector, scope) in Self.properties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
        self.listener = listener
    }

    func cancel() {
        queue.sync { isActive = false }
        guard let listener else { return }
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
        addresses.removeAll()
    }
}

/// The captured device's live input shape; nil once the device is gone.
private struct CapturedInputFormat: Equatable {
    let sampleRate: Float64
    let channelCount: UInt32

    init?(_ deviceID: AudioObjectID) {
        var alive: UInt32 = 0
        var sampleRate: Float64 = 0
        guard readAudioProperty(deviceID, kAudioDevicePropertyDeviceIsAlive, into: &alive), alive != 0,
              readAudioProperty(deviceID, kAudioDevicePropertyNominalSampleRate, into: &sampleRate)
        else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let list = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else {
            return nil
        }
        self.sampleRate = sampleRate
        channelCount = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }
}

private func readAudioProperty<Value>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    into value: inout Value
) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<Value>.size)
    return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    } == noErr
}

private func systemDefaultInputDeviceID() throws -> AudioObjectID {
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

final class CoreAudioDefaultInputMonitor: DefaultAudioInputMonitoring {
    var onDefaultInputChanged: ((AudioObjectID?) -> Void)?

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
            self?.onDefaultInputChanged?(try? systemDefaultInputDeviceID())
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
