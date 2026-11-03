import AVFoundation
import Foundation
import Vision

/// Receives one frame of lip geometry: seconds since the source started and
/// the 6 `LipGeometry` channels.
public typealias LipGeometryHandler = (_ t: Double, _ geometry: [Double]) -> Void

/// Anything that produces lip-geometry frames. `LipCaptureSession` reads the
/// camera; tests and the Caps Lock path can inject recorded frames instead.
///
/// Set `onFrame` before `start()`. Frames may arrive on any queue.
public protocol FrameSource: AnyObject {
    var onFrame: LipGeometryHandler? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

public enum LipCaptureError: Error, Equatable {
    /// Camera access is not granted. Request it through the app's permission
    /// flow first; this session never prompts.
    case notAuthorized
    case noCamera
    case configurationFailed
}

/// Camera -> Apple Vision face landmarks -> `LipGeometry` frames.
///
/// The owner must keep this object for as long as it wants frames.
/// AVCaptureVideoDataOutput does not retain its sample-buffer delegate, so a
/// session that nobody holds stops delivering frames at once (the spike's
/// last bug fix). Releasing the session stops it and releases the camera.
public final class LipCaptureSession: FrameSource {
    public static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    public static func availableDeviceNames() -> [String] {
        discovery().devices.map(\.localizedName)
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
    }

    /// Case-insensitive substring of the camera name, or nil for the default camera.
    public let deviceFilter: String?
    public var onFrame: LipGeometryHandler?
    public private(set) var isRunning = false

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.relayrunner.truewhisper.session")
    private let authorizationStatus: () -> AVAuthorizationStatus
    /// Strongly held here because the video output holds it weakly.
    private var processor: LipFrameProcessor?

    public init(deviceFilter: String? = nil,
                authorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) }) {
        self.deviceFilter = deviceFilter
        self.authorizationStatus = authorizationStatus
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard !isRunning else { return }
        guard authorizationStatus() == .authorized else { throw LipCaptureError.notAuthorized }

        let device: AVCaptureDevice?
        if let filter = deviceFilter {
            device = Self.discovery().devices.first { $0.localizedName.localizedCaseInsensitiveContains(filter) }
        } else {
            device = AVCaptureDevice.default(for: .video) ?? Self.discovery().devices.first
        }
        guard let device else { throw LipCaptureError.noCamera }

        let processor = LipFrameProcessor(onFrame: onFrame)
        let session = captureSession
        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .vga640x480
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(processor, queue: processor.queue)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw LipCaptureError.configurationFailed
            }
            session.addInput(input)
            session.addOutput(output)
        }
        self.processor = processor
        isRunning = true
        // startRunning blocks until the camera is up; keep it off the caller's thread.
        sessionQueue.async { session.startRunning() }
    }

    /// Stops capture and removes the camera input so macOS releases the device.
    /// Safe to call repeatedly.
    public func stop() {
        let session = captureSession
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
        processor = nil
        isRunning = false
    }
}

/// Runs Vision on each camera frame on its own serial queue.
final class LipFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "com.relayrunner.truewhisper.frames")
    private let request = VNDetectFaceLandmarksRequest()
    private let onFrame: LipGeometryHandler?
    private var start: CFTimeInterval?

    init(onFrame: LipGeometryHandler?) {
        self.onFrame = onFrame
        request.revision = VNDetectFaceLandmarksRequestRevision3
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if start == nil { start = ts }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([request]) } catch { return }
        guard let face = request.results?.first else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let g = LipGeometry.frame(from: face, imageSize: size) else { return }
        onFrame?(ts - (start ?? ts), g)
    }
}

/// Thread-safe frame buffer shared between the capture queue and a consumer.
public final class FrameBuffer {
    private let lock = NSLock()
    private var items: [(t: Double, g: [Double])] = []

    public init() {}

    public func push(_ t: Double, _ g: [Double]) { lock.lock(); items.append((t, g)); lock.unlock() }
    public func drain() -> [(t: Double, g: [Double])] { lock.lock(); defer { lock.unlock() }; let out = items; items = []; return out }
}
