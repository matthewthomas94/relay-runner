import AVFoundation
import Darwin
import Foundation

enum VoicePreviewFailure: LocalizedError {
    case busy, unsafeStorage, invalidAudio, previewFailed

    var errorDescription: String? {
        switch self {
        case .busy: return "Finish response playback or voice recording before previewing a voice."
        case .unsafeStorage: return "The voice audio lock in Application Support is unavailable."
        case .invalidAudio: return "The preview audio could not be played."
        case .previewFailed: return "Preview failed. Check the local voice runtime and try again."
        }
    }
}

/// The same advisory lock is held by Python immediately before response playback.
final class SettingsAudioLease {
    static let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("relay-runner", isDirectory: true)
    private var fd: Int32 = -1

    init(root: URL = SettingsAudioLease.supportRoot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fd = open(root.appendingPathComponent("voice-audio.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VoicePreviewFailure.unsafeStorage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw VoicePreviewFailure.busy
        }
    }

    func release() { if fd >= 0 { close(fd); fd = -1 } }
    deinit { release() }
}

@MainActor
@Observable
final class VoicePreviewController {
    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var error: String?
    private var generation = UUID()
    private var process: Process?
    private var player: AVAudioPlayer?

    static let sentence = "This is a computer generated voice preview. You can change the voice settings at any time."

    func stop() {
        generation = UUID()
        player?.stop()
        if let process, process.isRunning { VoicePreviewProcess.signal(process, SIGTERM) }
    }

    func preview(voice: String, rate: Double, appState: AppState) {
        guard !isBusy else { return }
        error = nil
        do {
            guard !appState.settingsAudioBusy else { throw VoicePreviewFailure.busy }
            let lease = try SettingsAudioLease()
            let capture = appState.sttEngine
            let captureToken: UUID?
            do { captureToken = try capture?.suspendForReferenceAudio() }
            catch { lease.release(); throw error }
            let token = UUID()
            generation = token
            isBusy = true
            status = "Generating preview…"
            Task {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-voice-preview-\(UUID().uuidString)")
                var launched: Process?
                var succeeded = false
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    let output = directory.appendingPathComponent("preview.wav")
                    let proc = try ProcessManager().voicePreviewProcess(name: voice, text: Self.sentence, output: output)
                    process = proc
                    launched = proc
                    try await VoicePreviewProcess.run(proc, cancelled: { generation != token })
                    let audio = try AVAudioPlayer(contentsOf: output)
                    audio.enableRate = true
                    audio.rate = Float(rate)
                    player = audio
                    status = "Playing preview…"
                    guard audio.play() else { throw VoicePreviewFailure.invalidAudio }
                    let playbackDeadline = Date().addingTimeInterval(65)
                    while audio.isPlaying {
                        guard generation == token else { throw CancellationError() }
                        guard Date() < playbackDeadline else { throw VoicePreviewFailure.invalidAudio }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    succeeded = generation == token
                } catch is CancellationError {
                    // Stop/reselect/window close is not a failed preview.
                } catch {
                    if generation == token { self.error = (error as? VoicePreviewFailure ?? .previewFailed).localizedDescription }
                }
                player?.stop()
                player = nil
                if let proc = launched { await VoicePreviewProcess.stop(proc) }
                process = nil
                try? FileManager.default.removeItem(at: directory)
                lease.release()
                if let captureToken { capture?.resumeAfterReferenceAudio(captureToken) }
                isBusy = false
                status = succeeded ? "Preview ready" : ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
