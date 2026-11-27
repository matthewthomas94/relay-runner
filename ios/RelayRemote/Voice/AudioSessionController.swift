import AVFoundation
import Foundation

/// Why the app holds its audio session in the background with nothing to
/// record or play. Kept here, in one place, so a later reason (the Relay ring)
/// joins the same hold.
enum KeepAliveReason: Hashable {
    /// RR-545: Reply notifications are on and allowed.
    case replyNotifications
}

/// Owns the shared `AVAudioSession`. The session is active while the app
/// records or plays (docs/specs/relay-remote.md, "Foreground and background"),
/// and otherwise only while a `KeepAliveReason` holds it: with neither, the app
/// suspends like any other.
///
/// The hold (RR-545) is the least intrusive configuration that keeps the app
/// running: the `playback` category mixed with other audio, so it neither
/// interrupts the user's music nor opens the microphone, with an
/// `AVAudioEngine` rendering silence, because an active session that plays
/// nothing is suspended. Recording or playing a reply switches to the voice
/// configuration and back, so a reply plays exactly as before.
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
    private var keepAliveReasons: Set<KeepAliveReason> = []
    private var hold: Hold?
    private var observers: [NSObjectProtocol] = []
    private let silence = AVAudioEngine()
    private var silenceSource: AVAudioSourceNode?

    private enum Hold {
        /// Recording or playing: `playAndRecord`, as before RR-545.
        case voice
        /// Only kept alive: mixable `playback` and silence.
        case silent
    }

    /// True while a `KeepAliveReason` holds the session.
    var isKeepingAlive: Bool { !keepAliveReasons.isEmpty }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        // A route or category change stops the engine; the hold restarts it.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: silence, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSilence() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setRecording(_ on: Bool) throws {
        recording = on
        try update()
    }

    /// Starts recording with the session switch off the main thread: moving
    /// to `playAndRecord` and activating can block for a good part of a
    /// second (longer with Bluetooth), and on the main thread that froze the
    /// talk button's press until the microphone was up (user, 2026-11-27).
    func startRecording() async throws {
        recording = true
        guard hold != .voice else { return }
        stopSilence()
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.applyVoice(AVAudioSession.sharedInstance())
            }.value
        } catch {
            recording = false
            updateSilence()
            throw error
        }
        hold = .voice
        isActive = true
        updateSilence()
    }

    func setPlaying(_ on: Bool) throws {
        playing = on
        try update()
    }

    /// Holds or releases the session for `reason` with nothing to record or play.
    func setKeepAlive(_ on: Bool, for reason: KeepAliveReason) throws {
        if on { keepAliveReasons.insert(reason) } else { keepAliveReasons.remove(reason) }
        do {
            try update()
        } catch {
            if on { keepAliveReasons.remove(reason) }
            throw error
        }
    }

    /// After an interruption ends the system expects the app to reactivate.
    func reactivate() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        updateSilence()
    }

    private func update() throws {
        let wanted: Hold? = recording || playing ? .voice : (keepAliveReasons.isEmpty ? nil : .silent)
        guard wanted != hold else { return }
        let session = AVAudioSession.sharedInstance()
        if wanted != .silent { stopSilence() }
        do {
            switch wanted {
            case .voice:
                try Self.applyVoice(session)
            case .silent:
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            case nil:
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            updateSilence()
            throw error
        }
        hold = wanted
        isActive = wanted != nil
        updateSilence()
    }

    /// The voice configuration: record and play, as before RR-545.
    nonisolated private static func applyVoice(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        // iOS mutes haptics while recording unless asked, which left
        // the tap that sends with no feedback.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    private func updateSilence() {
        guard hold == .silent else {
            stopSilence()
            return
        }
        guard !silence.isRunning else { return }
        if silenceSource == nil {
            let source = Self.makeSilenceSource()
            silence.attach(source)
            silence.connect(source, to: silence.mainMixerNode, format: source.outputFormat(forBus: 0))
            silenceSource = source
        }
        silence.prepare()
        try? silence.start()
    }

    private func stopSilence() {
        if silence.isRunning { silence.stop() }
    }

    /// Renders zeros on the audio thread, so it is built outside the main actor.
    private nonisolated static func makeSilenceSource() -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        return AVAudioSourceNode(format: format) { _, _, _, bufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
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
