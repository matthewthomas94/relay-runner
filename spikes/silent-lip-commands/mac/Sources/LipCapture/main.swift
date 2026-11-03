import AVFoundation
import Foundation
import Vision

// LipCapture: silent lip-command spike, entirely on-device.
//
//   LipCapture stream                      print one JSON object per frame: {"t": s, "g": [6 channels]}
//   LipCapture record --label stop [--takes 10] [--seconds 1.5]
//   LipCapture evaluate [--perms 500]      leave-one-out accuracy vs shuffled-label null
//   LipCapture decode [--max-distance 1.5] [--min-confidence 0.1] [--trigger-ratio 3]
//   LipCapture --list-devices
//
// Options: --device <name-substring>, --no-velocity. Dataset: ~/.lipspike/dataset.json (LIPSPIKE_DATASET).

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let useVelocity = !args.contains("--no-velocity")
let command = args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "stream"

if args.contains("--list-devices") {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
    for d in discovery.devices { print(d.localizedName) }
    exit(0)
}

// MARK: - Camera + Vision

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "lipcapture.frames")
    let request = VNDetectFaceLandmarksRequest()
    var start: CFTimeInterval?
    var frames = 0, faces = 0
    var onFrame: ((Double, [Double]) -> Void)?

    func configure(deviceFilter: String?) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        let device: AVCaptureDevice?
        if let f = deviceFilter {
            device = discovery.devices.first { $0.localizedName.localizedCaseInsensitiveContains(f) }
        } else {
            device = AVCaptureDevice.default(for: .video) ?? discovery.devices.first
        }
        guard let device else { throw NSError(domain: "LipCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"]) }
        stderr("camera: \(device.localizedName)")
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.addInput(try AVCaptureDeviceInput(device: device))
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
        onFrame?(ts - (start ?? ts), g)
        if frames % 300 == 0 { stderr("frames=\(frames) with_face=\(faces)") }
    }
}

/// Thread-safe frame buffer shared between the capture queue and the main thread.
final class FrameBuffer {
    private let lock = NSLock()
    private var items: [(t: Double, g: [Double])] = []
    func push(_ t: Double, _ g: [Double]) { lock.lock(); items.append((t, g)); lock.unlock() }
    func drain() -> [(t: Double, g: [Double])] { lock.lock(); defer { lock.unlock() }; let out = items; items = []; return out }
}

func startCamera(onFrame: @escaping (Double, [Double]) -> Void) -> Capture {
    let capture = Capture()
    capture.onFrame = onFrame
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; sem.signal() }
    sem.wait()
    guard granted else { stderr("camera access denied"); exit(2) }
    do { try capture.configure(deviceFilter: option("--device")) } catch { stderr("error: \(error.localizedDescription)"); exit(1) }
    capture.session.startRunning()
    return capture
}

// MARK: - Commands

func runStream() {
    let out = FileHandle.standardOutput
    _ = startCamera { t, g in
        let gs = g.map { String(format: "%.6f", $0) }.joined(separator: ",")
        out.write("{\"t\":\(String(format: "%.4f", t)),\"g\":[\(gs)]}\n".data(using: .utf8)!)
    }
    stderr("streaming geometry (ctrl-c to stop)")
    RunLoop.main.run()
}

func runRecord() {
    guard let label = option("--label") else { stderr("record needs --label"); exit(64) }
    let takes = Int(option("--takes") ?? "10") ?? 10
    let seconds = Double(option("--seconds") ?? "1.5") ?? 1.5
    var templates = Dataset.load()
    let buffer = FrameBuffer()
    _ = startCamera { t, g in buffer.push(t, g) }
    print("Recording \(takes) takes of '\(label)', \(seconds)s each. Dataset: \(Dataset.url.path)")
    print("Waiting for the camera to see a face...")
    while buffer.drain().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
    for k in 1...takes {
        print("[\(k)/\(takes)] Enter to record '\(label)'... ", terminator: "")
        _ = readLine()
        _ = buffer.drain()
        var frames: [[Double]] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            frames += buffer.drain().map(\.g)
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard frames.count >= 6 else { print("   too few frames; is the face in view? take discarded"); continue }
        templates.append(Template(label: label, frames: frames))
        print("   stored \(frames.count) frames")
    }
    do { try Dataset.save(templates) } catch { stderr("save failed: \(error)"); exit(1) }
    print("Saved. Dataset now has \(templates.count) takes across \(Set(templates.map(\.label)).count) labels.")
}

func runEvaluate() {
    let perms = Int(option("--perms") ?? "500") ?? 500
    let templates = Dataset.load()
    guard let ev = Evaluation.run(templates: templates, useVelocity: useVelocity, permutations: perms) else {
        stderr("need at least 2 labels with 2 takes each in \(Dataset.url.path)"); exit(1)
    }
    print(ev.report)
}

func runDecode() {
    let maxDistance = Double(option("--max-distance") ?? "1.5") ?? 1.5
    let minConfidence = Double(option("--min-confidence") ?? "0.1") ?? 0.1
    guard let clf = TemplateClassifier(templates: Dataset.load(), useVelocity: useVelocity) else {
        stderr("need at least 2 labels in \(Dataset.url.path)"); exit(1)
    }
    print("Vocabulary: \(clf.labels)")
    let seg = Segmenter()
    seg.triggerRatio = Double(option("--trigger-ratio") ?? "3") ?? 3
    seg.onSegment = { frames in
        let p = clf.predict(frames, maxDistance: maxDistance, minConfidence: minConfidence)
        let ranked = p.ranked.prefix(3).map { String(format: "%@:%.2f", $0.label, $0.distance) }.joined(separator: ", ")
        let tag = p.accepted ? (p.best ?? "?") : "? (\(p.best ?? "-"))"
        print(String(format: "%14@  conf=%.2f  frames=%d  [%@]", tag, p.confidence, frames.count, ranked))
    }
    let buffer = FrameBuffer()
    _ = startCamera { t, g in buffer.push(t, g) }
    seg.calibrate()
    print("Calibrating noise floor: keep your mouth still for 2 seconds...")
    while true {
        for f in buffer.drain() {
            seg.ingest(t: f.t, g: f.g)
            if !seg.isCalibrating, !seg.autoEnabled {
                seg.autoEnabled = true
                print(String(format: "Listening (noise floor=%.4f, threshold=%.4f). Mouth a word.", seg.noiseFloor ?? 0, seg.threshold ?? 0))
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

switch command {
case "stream": runStream()
case "record": runRecord()
case "evaluate": runEvaluate()
case "decode": runDecode()
default: stderr("unknown command \(command); use stream | record | evaluate | decode"); exit(64)
}
