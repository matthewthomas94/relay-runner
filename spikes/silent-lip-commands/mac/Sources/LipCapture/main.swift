import AVFoundation
import Foundation
import Vision

// LipCapture: open the default camera, run Vision face landmarks on every frame,
// print one JSON object per frame to stdout:
//   {"t": <seconds since start>, "g": [width, outer_h, inner_h, outer_area, inner_area, jaw]}
// Diagnostics go to stderr. Frames with no face are skipped.
//
// Usage: LipCapture [--device <name-substring>] [--list-devices]

let args = CommandLine.arguments
if args.contains("--list-devices") {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
    for d in discovery.devices { print(d.localizedName) }
    exit(0)
}
var deviceFilter: String? = nil
if let i = args.firstIndex(of: "--device"), i + 1 < args.count { deviceFilter = args[i + 1] }

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "lipcapture.frames")
    let request = VNDetectFaceLandmarksRequest()
    var start: CFTimeInterval?
    var frames = 0, faces = 0
    var out = FileHandle.standardOutput

    func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        let device: AVCaptureDevice?
        if let f = deviceFilter {
            device = discovery.devices.first { $0.localizedName.localizedCaseInsensitiveContains(f) }
        } else {
            device = AVCaptureDevice.default(for: .video) ?? discovery.devices.first
        }
        guard let device else { throw NSError(domain: "LipCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"]) }
        FileHandle.standardError.write("camera: \(device.localizedName)\n".data(using: .utf8)!)

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        request.revision = VNDetectFaceLandmarksRequestRevision3
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if start == nil { start = ts }
        frames += 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([request]) } catch { return }
        guard let face = request.results?.first else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let g = LipGeometry.frame(from: face, imageSize: size) else { return }
        faces += 1
        let t = ts - (start ?? ts)
        let gs = g.map { String(format: "%.6f", $0) }.joined(separator: ",")
        out.write("{\"t\":\(String(format: "%.4f", t)),\"g\":[\(gs)]}\n".data(using: .utf8)!)
        if frames % 300 == 0 {
            FileHandle.standardError.write("frames=\(frames) with_face=\(faces)\n".data(using: .utf8)!)
        }
    }
}

let capture = Capture()

// Request access first: creating the device input before the grant fails on a fresh install.
AVCaptureDevice.requestAccess(for: .video) { granted in
    guard granted else {
        FileHandle.standardError.write("camera access denied\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        try capture.configure()
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    capture.session.startRunning()
    FileHandle.standardError.write("streaming geometry (ctrl-c to stop)\n".data(using: .utf8)!)
}
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
RunLoop.main.run()
