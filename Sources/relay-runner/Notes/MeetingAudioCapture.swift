import AVFAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct MeetingCaptureSourceInfo: Equatable, Sendable {
    let sourceID: MeetingAudioSourceID
    let routeID: String
    let sampleRate: Int
    let channelCount: Int
}

enum MeetingAudioCaptureFailure: LocalizedError, Equatable {
    case permissionDenied(MeetingAudioSourceID)
    case unavailable(MeetingAudioSourceID, String)
    case unsupportedFormat(MeetingAudioSourceID, String)
    case startFailed(MeetingAudioSourceID, String)

    var sourceID: MeetingAudioSourceID {
        switch self {
        case .permissionDenied(let source), .unavailable(let source, _),
             .unsupportedFormat(let source, _), .startFailed(let source, _):
            return source
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied(.microphone):
            return "Microphone permission is required for local meeting speech."
        case .permissionDenied(.systemAudio):
            return "Screen Recording permission is required for computer and meeting audio capture."
        case .unavailable(let source, let message):
            return "The \(source.rawValue) source is unavailable: \(message)"
        case .unsupportedFormat(let source, let message):
            return "The \(source.rawValue) source has an unsupported audio format: \(message)"
        case .startFailed(let source, let message):
            return "The \(source.rawValue) source could not start: \(message)"
        }
    }
}

enum MeetingAudioCaptureEvent: Equatable, Sendable {
    case interrupted(String)
    case recovered(MeetingCaptureSourceInfo)
    case failed(MeetingAudioCaptureFailure)
}

protocol MeetingAudioCapturing: AnyObject {
    var sourceID: MeetingAudioSourceID { get }
    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo
    func stop() async
}

final class MeetingMicrophoneAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID = MeetingAudioSourceID.microphone

    private let lock = NSLock()
    private var lifecycle: AudioCaptureLifecycle?
    private var startupFailure: MeetingAudioCaptureFailure?

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        await stop()
        let microphoneAuthorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            microphoneAuthorized = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) {
                    continuation.resume(returning: $0)
                }
            }
        case .denied, .restricted:
            microphoneAuthorized = false
        @unknown default:
            microphoneAuthorized = false
        }
        guard microphoneAuthorized else {
            throw MeetingAudioCaptureFailure.permissionDenied(.microphone)
        }
        let lifecycle = AudioCaptureLifecycle(
            sampleHandler: { samples in
                let duration = UInt64(samples.count) * 1_000_000_000 / 16_000
                let now = DispatchTime.now().uptimeNanoseconds
                sampleHandler(MeetingAudioFrame(
                    samples: samples,
                    presentationTimeNanoseconds: now > duration ? now - duration : 0
                ))
            },
            isRecording: { false }
        )
        lifecycle.onWillReconfigure = { interruption in
            eventHandler(.interrupted(
                "Microphone route changed (\(interruption.reasons.sorted().joined(separator: ",")))."
            ))
        }
        lifecycle.onRecovery = { [weak self] recovery in
            guard let self else { return }
            if let error = recovery.error {
                let failure = Self.captureFailure(from: error)
                if recovery.reasons.contains("initial-start") {
                    self.lock.withMeetingCaptureLock {
                        self.startupFailure = failure
                    }
                } else {
                    eventHandler(.failed(failure))
                }
            } else if let route = recovery.route {
                eventHandler(.recovered(Self.info(route)))
            }
        }
        lock.withMeetingCaptureLock {
            self.lifecycle = lifecycle
            self.startupFailure = nil
        }
        let route: AudioInputRoute?
        do {
            route = try lifecycle.start()
        } catch let error as AudioCaptureFailure {
            _ = finishStartup()
            throw Self.captureFailure(from: error)
        } catch {
            _ = finishStartup()
            throw MeetingAudioCaptureFailure.startFailed(.microphone, error.localizedDescription)
        }
        let failure = finishStartup()
        guard let route else {
            throw failure ?? MeetingAudioCaptureFailure.unavailable(
                .microphone,
                "No usable system-default input is connected."
            )
        }
        return Self.info(route)
    }

    func stop() async {
        let lifecycle = lock.withMeetingCaptureLock { () -> AudioCaptureLifecycle? in
            defer {
                self.lifecycle = nil
                self.startupFailure = nil
            }
            return self.lifecycle
        }
        lifecycle?.stop()
    }

    static func captureFailure(from error: AudioCaptureFailure) -> MeetingAudioCaptureFailure {
        switch error {
        case .incompatibleFormat(_, _), .converterUnavailable(_, _):
            return .unsupportedFormat(.microphone, error.localizedDescription)
        case .noInput, .coreAudio, .engineStart:
            return .unavailable(.microphone, error.localizedDescription)
        }
    }

    private func finishStartup() -> MeetingAudioCaptureFailure? {
        lock.withMeetingCaptureLock {
            defer { startupFailure = nil }
            return startupFailure
        }
    }

    private static func info(_ route: AudioInputRoute) -> MeetingCaptureSourceInfo {
        MeetingCaptureSourceInfo(
            sourceID: .microphone,
            routeID: String(route.deviceID),
            sampleRate: 16_000,
            channelCount: 1
        )
    }
}

/// ScreenCaptureKit is already hosted by Relay Runner's signed app process.
/// This audio-only stream captures the system mix, excludes Relay Runner's own
/// playback, and emits 16 kHz mono without producing screenshots or video.
final class MeetingSystemAudioCapture: NSObject, MeetingAudioCapturing, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable
{
    let sourceID = MeetingAudioSourceID.systemAudio

    private let outputQueue = DispatchQueue(label: "com.relayrunner.meeting-system-audio")
    private let lock = NSLock()
    private var stream: SCStream?
    private var sampleHandler: (@Sendable (MeetingAudioFrame) -> Void)?
    private var eventHandler: (@Sendable (MeetingAudioCaptureEvent) -> Void)?
    private var reportedFormatFailure = false

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        await stop()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw MeetingAudioCaptureFailure.permissionDenied(.systemAudio)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw MeetingAudioCaptureFailure.startFailed(.systemAudio, error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw MeetingAudioCaptureFailure.unavailable(.systemAudio, "No display is available.")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            lock.withMeetingCaptureLock {
                self.stream = stream
                self.sampleHandler = sampleHandler
                self.eventHandler = eventHandler
                self.reportedFormatFailure = false
            }
            try await stream.startCapture()
        } catch {
            lock.withMeetingCaptureLock {
                self.stream = nil
                self.sampleHandler = nil
                self.eventHandler = nil
            }
            throw MeetingAudioCaptureFailure.startFailed(.systemAudio, error.localizedDescription)
        }
        return MeetingCaptureSourceInfo(
            sourceID: .systemAudio,
            routeID: "display-\(display.displayID)",
            sampleRate: 16_000,
            channelCount: 1
        )
    }

    func stop() async {
        let stream = lock.withMeetingCaptureLock { () -> SCStream? in
            defer {
                self.stream = nil
                self.sampleHandler = nil
                self.eventHandler = nil
            }
            return self.stream
        }
        guard let stream else { return }
        try? stream.removeStreamOutput(self, type: .audio)
        try? await stream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else {
            return
        }
        do {
            let samples = try Self.floatSamples(from: sampleBuffer)
            guard !samples.isEmpty else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let fallbackDuration = UInt64(samples.count) * 1_000_000_000 / 16_000
            let now = DispatchTime.now().uptimeNanoseconds
            let fallback = now > fallbackDuration ? now - fallbackDuration : 0
            let timestamp: UInt64
            if presentationTime.isNumeric, presentationTime.seconds >= 0 {
                timestamp = UInt64((presentationTime.seconds * 1_000_000_000).rounded())
            } else {
                timestamp = fallback
            }
            lock.withMeetingCaptureLock { sampleHandler }?(MeetingAudioFrame(
                samples: samples,
                presentationTimeNanoseconds: timestamp
            ))
        } catch {
            let handler: (@Sendable (MeetingAudioCaptureEvent) -> Void)? = lock.withMeetingCaptureLock {
                guard !reportedFormatFailure else { return nil }
                reportedFormatFailure = true
                return eventHandler
            }
            handler?(.failed(.unsupportedFormat(
                MeetingAudioSourceID.systemAudio,
                error.localizedDescription
            )))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = lock.withMeetingCaptureLock { eventHandler }
        handler?(.failed(.unavailable(.systemAudio, error.localizedDescription)))
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let formatDescription = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw MeetingAudioCaptureFailure.unsupportedFormat(
                .systemAudio,
                "The stream has no linear PCM description."
            )
        }
        let format = description.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              Int(format.mSampleRate.rounded()) == 16_000,
              format.mChannelsPerFrame == 1,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        else {
            throw MeetingAudioCaptureFailure.unsupportedFormat(
                .systemAudio,
                "Expected Float32 PCM at 16 kHz mono."
            )
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr, requiredSize > 0 else {
            throw MeetingAudioCaptureFailure.unsupportedFormat(
                .systemAudio,
                "Core Media could not size the audio buffer list (status \(status))."
            )
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw MeetingAudioCaptureFailure.unsupportedFormat(
                .systemAudio,
                "Core Media could not read system audio (status \(status))."
            )
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let data = first.mData else { return [] }
        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: sampleCount
        ))
    }
}

private extension NSLock {
    func withMeetingCaptureLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
