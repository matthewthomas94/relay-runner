import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Arguments for the app-hosted Relay Vision `record` tool, parsed and clamped in one place so
/// the defaults the MCP helper documents are the ones the app applies.
struct RelayScreenRecordingRequest: Equatable {
    static let defaultDuration: TimeInterval = 4
    static let minimumDuration: TimeInterval = 0.5
    static let maximumDuration: TimeInterval = 30
    static let defaultFramesPerSecond = 15
    static let maximumFramesPerSecond = 30
    /// Claude Code re-encodes images over 2000 px; recordings keep the same ceiling so a frame
    /// pulled from the video lines up with a `screenshot` of the same display.
    static let maximumLongEdge = 2000

    var duration: TimeInterval
    var framesPerSecond: Int
    var displayIndex: Int
    var outputURL: URL

    init(
        arguments: [String: Any],
        now: Date = Date(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        let requestedDuration = (arguments["duration_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultDuration
        duration = requestedDuration.isFinite
            ? min(Self.maximumDuration, max(Self.minimumDuration, requestedDuration))
            : Self.defaultDuration

        let requestedFPS = (arguments["fps"] as? NSNumber)?.intValue ?? Self.defaultFramesPerSecond
        framesPerSecond = min(Self.maximumFramesPerSecond, max(1, requestedFPS))

        displayIndex = (arguments["display_index"] as? NSNumber)?.intValue ?? 0

        if let path = arguments["output_path"] as? String,
           !path.trimmingCharacters(in: .whitespaces).isEmpty {
            var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if url.pathExtension.lowercased() != "mp4" {
                url.appendPathExtension("mp4")
            }
            outputURL = url
        } else {
            outputURL = temporaryDirectory.appendingPathComponent(Self.defaultFileName(now: now))
        }
    }

    /// Frames the recording should contain at the requested rate.
    var frameCount: Int {
        max(1, Int((duration * Double(framesPerSecond)).rounded()))
    }

    static func defaultFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "relay-vision-\(formatter.string(from: now)).mp4"
    }

    /// Scales native pixels down so the long edge is at most `maximumLongEdge`, keeping both
    /// dimensions even for H.264.
    static func outputSize(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        let longEdge = max(nativeWidth, nativeHeight, 1)
        let scale = min(1, Double(maximumLongEdge) / Double(longEdge))
        func even(_ value: Double) -> Int {
            max(2, Int(value.rounded(.down)) & ~1)
        }
        return (even(Double(nativeWidth) * scale), even(Double(nativeHeight) * scale))
    }
}

struct RelayScreenRecordingSummary {
    let request: RelayScreenRecordingRequest
    let width: Int
    let height: Int
    let framesWritten: Int
    let fileSize: Int
}

/// Records one display through ScreenCaptureKit into an H.264 mp4. The stream delivers frames
/// only when pixels change, so a timer samples the latest frame at the requested rate: the file
/// always runs for the whole duration at a constant frame rate, even over a static screen.
final class RelayScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let request: RelayScreenRecordingRequest
    private let size: (width: Int, height: Int)
    private let queue = DispatchQueue(label: "com.relayrunner.relay-vision-record")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var latestFrame: CVPixelBuffer?
    private var sampler: DispatchSourceTimer?
    private var firstFrameDeadline: DispatchSourceTimer?
    private var nextFrameIndex = 0
    private var framesWritten = 0
    private var finished = false
    private var completion: ((Result<Int, Error>) -> Void)?

    private static let firstFrameTimeout: TimeInterval = 5

    init(request: RelayScreenRecordingRequest, nativeWidth: Int, nativeHeight: Int) {
        self.request = request
        self.size = RelayScreenRecordingRequest.outputSize(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    func record(filter: SCContentFilter) async throws -> RelayScreenRecordingSummary {
        let outputURL = request.outputURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitsPerSecond = max(4_000_000, size.width * size.height * request.framesPerSecond / 5)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoMaxKeyFrameIntervalKey: request.framesPerSecond * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RelayHostedToolError.message("The video writer rejected the recording settings.")
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
        guard writer.startWriting() else {
            throw RelayHostedToolError.message(
                "Could not start writing \(outputURL.path): \(writer.error?.localizedDescription ?? "unknown error")"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.framesPerSecond))
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.stream = stream
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        let framesWritten: Int
        do {
            framesWritten = try await awaitFrames(from: stream)
        } catch {
            // A failed take leaves nothing behind: stop the stream, abandon the writer and
            // remove the partial file before surfacing the error.
            try? stream.removeStreamOutput(self, type: .screen)
            try? await stream.stopCapture()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        try? stream.removeStreamOutput(self, type: .screen)
        try? await stream.stopCapture()
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RelayHostedToolError.message(
                "Recording could not be saved: \(writer.error?.localizedDescription ?? "unknown error")"
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return RelayScreenRecordingSummary(
            request: request,
            width: size.width,
            height: size.height,
            framesWritten: framesWritten,
            fileSize: fileSize
        )
    }

    /// Starts capture and resolves with the number of frames written once the take ends.
    private func awaitFrames(from stream: SCStream) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.completion = { continuation.resume(with: $0) }
                let deadline = DispatchSource.makeTimerSource(queue: self.queue)
                deadline.schedule(deadline: .now() + Self.firstFrameTimeout)
                deadline.setEventHandler { [weak self] in
                    guard let self, self.sampler == nil else { return }
                    self.finish(.failure(RelayHostedToolError.message(
                        "The display produced no frames within \(Int(Self.firstFrameTimeout))s."
                    )))
                }
                deadline.resume()
                self.firstFrameDeadline = deadline
            }
            Task {
                do {
                    try await stream.startCapture()
                } catch {
                    self.queue.async {
                        self.finish(.failure(RelayHostedToolError.message(
                            "Recording capture failed to start: \(error.localizedDescription)"
                        )))
                    }
                }
            }
        }
    }

    // MARK: - Sampling (all on `queue`)

    private func startSampling() {
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        let interval = 1.0 / Double(request.framesPerSecond)
        let sampler = DispatchSource.makeTimerSource(queue: queue)
        sampler.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        sampler.setEventHandler { [weak self] in
            self?.appendFrame()
        }
        sampler.resume()
        self.sampler = sampler
    }

    private func appendFrame() {
        guard !finished, let input, let adaptor, let latestFrame else { return }
        if nextFrameIndex >= request.frameCount {
            finish(.success(framesWritten))
            return
        }
        let time = CMTime(value: CMTimeValue(nextFrameIndex), timescale: CMTimeScale(request.framesPerSecond))
        nextFrameIndex += 1
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(latestFrame, withPresentationTime: time) {
            framesWritten += 1
        } else if let error = writer?.error {
            finish(.failure(RelayHostedToolError.message("Recording failed while writing frames: \(error.localizedDescription)")))
        }
    }

    private func finish(_ result: Result<Int, Error>) {
        guard !finished else { return }
        finished = true
        sampler?.cancel()
        sampler = nil
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        latestFrame = nil
        let completion = self.completion
        self.completion = nil
        switch result {
        case .success(let frames) where frames == 0:
            completion?(.failure(RelayHostedToolError.message("Recording wrote no frames.")))
        default:
            completion?(result)
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        latestFrame = pixelBuffer
        if sampler == nil {
            startSampling()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.finish(.failure(RelayHostedToolError.message("Recording stopped early: \(error.localizedDescription)")))
        }
    }
}
