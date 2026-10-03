import AVFoundation
import Foundation

@MainActor
protocol VoiceSampleRecording: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func record(forDuration: TimeInterval) -> Bool
    func stop()
}

extension AVAudioRecorder: VoiceSampleRecording {}

/// A settings-only recording. Its output is never routed through STT or a FIFO.
@MainActor
@Observable
final class VoiceSampleRecorder {
    private(set) var isBusy = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var error: String?
    private var generation = UUID()
    private var recorder: VoiceSampleRecording?
    private var finishRequested = false

    typealias Factory = (URL) throws -> VoiceSampleRecording
    private let factory: Factory
    private let decode: (URL) throws -> [Float]
    private let clock: () -> Date

    init(factory: @escaping Factory = { url in
        try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }, decode: @escaping (URL) throws -> [Float] = CustomVoiceStore.decode,
         clock: @escaping () -> Date = Date.init) {
        self.factory = factory
        self.decode = decode
        self.clock = clock
    }

    func stop() {
        if recorder == nil { cancel(); return }
        finishRequested = true
        recorder?.stop()
    }
    func cancel() { generation = UUID(); recorder?.stop() }

    func record(appState: AppState, completion: @escaping ([Float]) -> Void) {
        record(requestPermission: appState.permissions.requestMicrophone,
               acquire: {
                   guard !appState.settingsAudioBusy else { throw CustomVoiceFailure.busy }
                   let lease = try SettingsAudioLease()
                   let capture = appState.sttEngine
                   let token: UUID?
                   do { token = try capture?.suspendForReferenceAudio() }
                   catch { lease.release(); throw error }
                   return {
                       lease.release()
                       if let token { capture?.resumeAfterReferenceAudio(token) }
                   }
               }, permissionStillGranted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
               sessionActive: { appState.referenceRecordingAllowed },
               completion: completion)
    }

    /// Dependency-injected lifecycle permits permission/cancel/device tests
    /// without opening a real microphone or changing the running app.
    /// `sessionActive` is the same session boundary command capture obeys: it
    /// is checked before the permission prompt, after it, and while recording.
    func record(requestPermission: (@escaping (Bool) -> Void) -> Void,
                acquire: @escaping () throws -> (() -> Void),
                permissionStillGranted: @escaping () -> Bool,
                sessionActive: @escaping () -> Bool,
                completion: @escaping ([Float]) -> Void) {
        guard !isBusy else { return }
        elapsed = 0
        error = nil
        guard sessionActive() else {
            error = CustomVoiceFailure.sessionRequired.localizedDescription
            return
        }
        isBusy = true
        finishRequested = false
        let token = UUID()
        generation = token
        requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.generation == token else { self.isBusy = false; return }
                guard granted else {
                    self.error = CustomVoiceFailure.permission.localizedDescription
                    self.isBusy = false
                    return
                }
                guard sessionActive() else {
                    self.error = CustomVoiceFailure.sessionRequired.localizedDescription
                    self.isBusy = false
                    return
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-voice-recording-\(UUID().uuidString)")
                var release: (() -> Void)?
                defer {
                    self.recorder?.stop()
                    self.recorder = nil
                    release?()
                    try? FileManager.default.removeItem(at: directory)
                    self.isBusy = false
                }
                do {
                    release = try acquire()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    let url = directory.appendingPathComponent("reference.wav")
                    let recorder = try self.factory(url)
                    self.recorder = recorder
                    guard recorder.record(forDuration: 10) else { throw CustomVoiceFailure.invalidAudio }
                    let deadline = self.clock().addingTimeInterval(10)
                    while recorder.isRecording && !self.finishRequested && self.clock() < deadline {
                        guard self.generation == token else { throw CancellationError() }
                        guard permissionStillGranted() else { throw CustomVoiceFailure.permission }
                        guard sessionActive() else { throw CustomVoiceFailure.sessionRequired }
                        self.elapsed = min(10, recorder.currentTime)
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    recorder.stop()
                    guard self.generation == token else { throw CancellationError() }
                    guard permissionStillGranted() else { throw CustomVoiceFailure.permission }
                    guard sessionActive() else { throw CustomVoiceFailure.sessionRequired }
                    let samples = try self.decode(url)
                    guard samples.count >= 120_000 else { throw CustomVoiceFailure.duration }
                    // Recording output enters the exact same editor/import pipeline.
                    completion(Array(samples.prefix(240_000)))
                } catch is CancellationError {
                    // Cancel, retake, close and session audio all discard the capture.
                } catch {
                    self.error = (error as? CustomVoiceFailure)?.localizedDescription ?? "Recording failed. Check the microphone, then try again."
                }
            }
        }
    }
}
