import AppKit
import ApplicationServices

/// Pauses/resumes system media playback during voice interaction.
/// Simulates the media play/pause key via CGEvent (works with all apps
/// including browser media like YouTube).
final class MediaController {

    private var didPauseMedia = false

    init() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        if trusted {
            NSLog("[MediaController] Ready")
        } else {
            NSLog("[MediaController] Accessibility NOT granted — add VoiceTerminal to System Settings > Privacy & Security > Accessibility")
        }
    }

    // MARK: - Public

    func pauseIfPlaying() {
        guard !didPauseMedia, AXIsProcessTrusted() else { return }
        postMediaKey()
        didPauseMedia = true
        NSLog("[MediaController] Paused")
    }

    func resumeIfWePaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        guard AXIsProcessTrusted() else { return }
        postMediaKey()
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
