import AppKit
import CoreGraphics
import Foundation

/// Activation key gesture detection state machine.
/// Supports Caps Lock (default) or any configurable key.
///
/// Gesture vocabulary:
///   - Single press + hold: enter recording mode
///   - Press again: stop recording, send text
///   - Double-tap: play queued TTS / replay last
final class CapsLockGesture {

    enum Event {
        case startRecording
        case stopRecording(text: String)
        case interrupt
        case play
    }

    /// Threshold before a held key counts as "recording" (not a tap)
    private let recordThresholdSec: Double = 0.3
    /// Maximum gap between taps in a multi-tap gesture
    private let tapWindowSec: Double = 0.6
    /// Wait after last transition before firing gesture
    private let settleMs: Double = 0.7

    private var prevKeyOn: Bool
    private var recording = false
    private var transitions: [Date] = []

    // Custom key support
    private let useCapsLock: Bool
    private let targetKeyCode: UInt16
    private let targetModifiers: NSEvent.ModifierFlags
    private var customKeyDown = false
    private var keyMonitors: [Any] = []

    init(activationKey: String = "") {
        if activationKey.isEmpty {
            useCapsLock = true
            targetKeyCode = 0
            targetModifiers = []
        } else {
            useCapsLock = false
            let (code, mods) = Self.parseKeyString(activationKey)
            targetKeyCode = code ?? 0
            targetModifiers = mods
        }

        prevKeyOn = useCapsLock ? Self.isCapsLockOn() : false

        if !useCapsLock {
            startKeyMonitor()
        }
    }

    static func isCapsLockOn() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskAlphaShift)
    }

    private var isKeyOn: Bool {
        useCapsLock ? Self.isCapsLockOn() : customKeyDown
    }

    /// Poll the activation key state and return any gesture event detected.
    /// Call this at ~50ms intervals.
    func poll(currentSegment: String) -> Event? {
        let keyOn = isKeyOn
        let now = Date()

        // Detect state transition
        if keyOn != prevKeyOn {
            let isRapid = transitions.last.map { now.timeIntervalSince($0) < tapWindowSec } ?? true
            if isRapid && !recording {
                transitions.append(now)
            } else if !recording {
                transitions = [now]
            }

            // Key just activated — clear audio for fresh recording
            if keyOn {
                prevKeyOn = keyOn
                return .startRecording
            }

            // Key just deactivated while recording — send text
            if !keyOn && recording {
                recording = false
                transitions.removeAll()
                prevKeyOn = keyOn
                if !currentSegment.isEmpty {
                    return .stopRecording(text: currentSegment)
                } else {
                    return .interrupt
                }
            }

            prevKeyOn = keyOn
            return nil
        }

        // Check if a rapid tap sequence has settled
        if !transitions.isEmpty && !recording {
            if let last = transitions.last, now.timeIntervalSince(last) > settleMs {
                let count = transitions.count

                if count >= 2 {
                    transitions.removeAll()
                    return .play
                }
            }
        }

        // If key is off, nothing to do
        if !keyOn { return nil }

        // Enter recording mode once held past tap threshold
        if !recording {
            if let first = transitions.first, now.timeIntervalSince(first) >= recordThresholdSec {
                recording = true
                transitions.removeAll()
            }
        }

        return nil
    }

    var isRecording: Bool { recording }

    func reset() {
        recording = false
        transitions.removeAll()
        prevKeyOn = isKeyOn
    }

    // MARK: - Custom key monitoring

    private func startKeyMonitor() {
        // Global monitor for key events in other apps
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        if let global { keyMonitors.append(global) }

        // Local monitor for key events when VoiceTerminal has focus
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        if let local { keyMonitors.append(local) }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // Modifier key used as activation key (e.g. Fn, Ctrl alone)
            guard event.keyCode == targetKeyCode else { return }
            customKeyDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(targetModifiers)
            return
        }

        guard event.keyCode == targetKeyCode else { return }

        // Check modifiers if specified (ignore for plain keys like F5)
        if !targetModifiers.isEmpty {
            let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard current == targetModifiers else {
                customKeyDown = false
                return
            }
        }

        customKeyDown = event.type == .keyDown
    }

    private func stopKeyMonitor() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors.removeAll()
    }

    // MARK: - Key string parsing (matches KeyCaptureView format)

    static func parseKeyString(_ keyString: String) -> (UInt16?, NSEvent.ModifierFlags) {
        let parts = keyString.split(separator: "+").map(String.init)
        guard let keyName = parts.last else { return (nil, []) }

        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "Ctrl":  modifiers.insert(.control)
            case "Alt":   modifiers.insert(.option)
            case "Shift": modifiers.insert(.shift)
            case "Cmd":   modifiers.insert(.command)
            default: break
            }
        }

        let code = keyCodeFor(keyName)
        return (code, modifiers)
    }

    private static func keyCodeFor(_ name: String) -> UInt16? {
        switch name {
        case "F1":     return 122
        case "F2":     return 120
        case "F3":     return 99
        case "F4":     return 118
        case "F5":     return 96
        case "F6":     return 97
        case "F7":     return 98
        case "F8":     return 100
        case "F9":     return 101
        case "F10":    return 109
        case "F11":    return 103
        case "F12":    return 111
        case "Return": return 36
        case "Tab":    return 48
        case "Space":  return 49
        default:
            if name.count == 1, let char = name.lowercased().first {
                let charMap: [Character: UInt16] = [
                    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
                    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
                    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
                    "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
                    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
                ]
                return charMap[char]
            }
            return nil
        }
    }

    deinit {
        stopKeyMonitor()
    }
}
