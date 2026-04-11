import AppKit

/// Pauses/resumes system media playback during voice interaction.
/// Tries MediaRemote.framework first (separate pause/play commands),
/// falls back to simulating the media play/pause key via CGEvent.
final class MediaController {

    private typealias MRSendCommand = @convention(c) (Int, AnyObject?) -> Bool
    private let sendCommand: MRSendCommand?

    private var didPauseMedia = false
    private var useKeySimulation: Bool

    init() {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              CFBundleLoadExecutable(bundle),
              let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else {
            NSLog("[MediaController] MediaRemote unavailable, using key simulation")
            sendCommand = nil
            useKeySimulation = true
            return
        }

        sendCommand = unsafeBitCast(ptr, to: MRSendCommand.self)
        useKeySimulation = false
        NSLog("[MediaController] Using MediaRemote")
    }

    // MARK: - Public

    func pauseIfPlaying() {
        guard !didPauseMedia else { return }

        if useKeySimulation {
            postMediaKey()
        } else if let sendCommand {
            let result = sendCommand(1, nil)   // kMRMediaRemoteCommandPause
            NSLog("[MediaController] MR pause result=\(result)")
            // If MediaRemote reports failure, try key simulation next time
            if !result {
                NSLog("[MediaController] MR failed, switching to key simulation")
                useKeySimulation = true
                postMediaKey()
            }
        }

        didPauseMedia = true
        NSLog("[MediaController] Paused")
    }

    func resumeIfWePaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false

        if useKeySimulation {
            postMediaKey()
        } else {
            _ = sendCommand?(0, nil)   // kMRMediaRemoteCommandPlay
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
