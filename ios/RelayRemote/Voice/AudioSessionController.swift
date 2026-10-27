import AVFoundation
import Foundation

/// Owns the shared `AVAudioSession`. The session is active only while the app
/// records or plays (docs/specs/relay-remote.md, "Foreground and background"),
/// which keeps the `audio` background mode honest: with nothing to record or
/// play, the app suspends like any other.
@MainActor
final class AudioSessionController {
    enum Interruption: Equatable {
        case began
        case ended(shouldResume: Bool)
    }

    var onInterruption: ((Interruption) -> Void)?
    /// The output route went away (headphones unplugged, a car disconnected).
    var onRouteLost: (() -> Void)?
    private(set) var isActive = false
    private var recording = false
    private var playing = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setRecording(_ on: Bool) throws {
        recording = on
        try update()
    }

    func setPlaying(_ on: Bool) throws {
        playing = on
        try update()
    }

    /// After an interruption ends the system expects the app to reactivate.
    func reactivate() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func update() throws {
        let wanted = recording || playing
        guard wanted != isActive else { return }
        let session = AVAudioSession.sharedInstance()
        if wanted {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        isActive = wanted
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: raw)
            onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable { onRouteLost?() }
    }
}
