import AppKit
import ApplicationServices

/// Pauses/resumes system media playback during voice interaction.
/// Uses MRMediaRemoteSendCommand for directed pause/play (idempotent —
/// sending "pause" to already-paused media is a no-op).
/// Uses MRMediaRemoteGetNowPlayingApplicationIsPlaying to decide whether
/// to resume — only resumes if media was detected as playing before pause.
/// Note: some apps (e.g. Arc browser) misreport their playing state,
/// in which case media will pause correctly but won't auto-resume.
final class MediaController {

    private typealias MRSendCommandFn = @convention(c) (Int, AnyObject?) -> Bool
    private typealias MRIsPlayingFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private let sendCommand: MRSendCommandFn?
    private let isPlayingFn: MRIsPlayingFn?
    private var didPauseMedia = false

    init() {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        var cmd: MRSendCommandFn? = nil
        var isPlay: MRIsPlayingFn? = nil

        if let bundle = CFBundleCreate(kCFAllocatorDefault, url),
           CFBundleLoadExecutable(bundle) {
            if let ptr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString
            ) {
                cmd = unsafeBitCast(ptr, to: MRSendCommandFn.self)
            }
            if let ptr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
            ) {
                isPlay = unsafeBitCast(ptr, to: MRIsPlayingFn.self)
            }
        }

        sendCommand = cmd
        isPlayingFn = isPlay

        let trusted = AXIsProcessTrusted()

        NSLog("[MediaController] Ready (MR commands: \(cmd != nil), state: \(isPlay != nil), accessibility: \(trusted))")
    }

    // MARK: - Public

    func pauseIfPlaying() {
        guard !didPauseMedia else { return }

        // Always send directed pause — idempotent, safe for already-paused media
        if let sendCommand {
            _ = sendCommand(1, nil)   // kMRMediaRemoteCommandPause
        } else if AXIsProcessTrusted() {
            // No MR commands — can't safely toggle without state detection
            guard let isPlayingFn else { return }
            isPlayingFn(DispatchQueue.main) { [weak self] isPlaying in
                guard let self, !self.didPauseMedia, isPlaying else { return }
                self.postMediaKey()
                self.didPauseMedia = true
                NSLog("[MediaController] Paused via toggle")
            }
            return
        } else {
            return
        }

        // Only set didPauseMedia if we can confirm media was actually playing.
        // This prevents auto-resume from unpausing manually-paused media.
        if let isPlayingFn {
            isPlayingFn(DispatchQueue.main) { [weak self] isPlaying in
                guard let self else { return }
                self.didPauseMedia = isPlaying
                NSLog("[MediaController] Paused (isPlaying=\(isPlaying), willResume=\(isPlaying))")
            }
        } else {
            // No state detection — assume we paused something
            didPauseMedia = true
            NSLog("[MediaController] Paused (no state detection, willResume=true)")
        }
    }

    func resumeIfWePaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false

        if let sendCommand {
            _ = sendCommand(0, nil)   // kMRMediaRemoteCommandPlay
        } else if AXIsProcessTrusted() {
            postMediaKey()
        }

        NSLog("[MediaController] Resumed")
    }

    // MARK: - Media key simulation (NX_KEYTYPE_PLAY = 16)

    private func postMediaKey() {
        post(keyType: 16, down: true)
        post(keyType: 16, down: false)
    }

    private func post(keyType: Int, down: Bool) {
        let flagByte = down ? 0x0a : 0x0b
        let data1 = (keyType << 16) | (flagByte << 8)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(flagByte << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
