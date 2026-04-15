import AppKit
import CoreGraphics
import Foundation

/// Activation key gesture detection state machine.
///
/// Gesture vocabulary:
///   - Caps Lock (or configured key): toggle recording
///   - Double-tap Option: play queued TTS / replay last
///   - Double-tap Control: cancel recording / dismiss TTS
final class CapsLockGesture {

    enum Event {
        case startRecording
        case stopRecording(text: String)
        case cancel
        case interrupt
        case play
    }

    /// Threshold before a held key counts as "recording" (not a tap)
    private let recordThresholdSec: Double = 0.5
    /// Maximum gap between taps in a multi-tap gesture
    private let tapWindowSec: Double = 0.6

    private var prevKeyOn: Bool
    private var recording = false
    private var transitions: [Date] = []

    // Custom key support
    private let useCapsLock: Bool
    private let targetKeyCode: UInt16
    private let targetModifiers: NSEvent.ModifierFlags
    private var customKeyDown = false
    private var keyMonitors: [Any] = []

    // Menu-driven activation override (nil = use hardware state)
    private var manualKeyDown: Bool?

    /// After an external `reset()` while the key is held, suppress all events
    /// until the key is physically released and pressed again.
    private var suppressed = false

    // Modifier double-tap tracking
    private var optionTaps: [Date] = []
    private var optionWasDown = false
    private var controlTaps: [Date] = []
    private var controlWasDown = false
    private var pendingPlay = false
    private var pendingCancel = false

    init(activationKey: String = "") {
        let isCapsLock = activationKey.isEmpty
            || activationKey.lowercased() == "caps lock"
            || activationKey.lowercased() == "capslock"
        if isCapsLock {
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
        startModifierMonitor()
    }

    static func isCapsLockOn() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskAlphaShift)
    }

    private var isKeyOn: Bool {
        if let manual = manualKeyDown { return manual }
        return useCapsLock ? Self.isCapsLockOn() : customKeyDown
    }

    /// Toggle recording from the menu button.
    func toggleActivation() {
        if manualKeyDown != nil {
            manualKeyDown = nil
        } else {
            let current = useCapsLock ? Self.isCapsLockOn() : customKeyDown
            manualKeyDown = !current
        }
    }

    /// Poll the activation key state and return any gesture event detected.
    /// Call this at ~50ms intervals.
    func poll(currentSegment: String) -> Event? {
        // Check modifier double-tap events first
        if pendingCancel {
            pendingCancel = false
            return .cancel
        }
        if pendingPlay {
            pendingPlay = false
            return .play
        }

        let keyOn = isKeyOn

        // After an external reset while the key was held, wait for release
        if suppressed {
            if !keyOn {
                suppressed = false
                prevKeyOn = false
            }
            return nil
        }

        // Detect state transition
        if keyOn != prevKeyOn {
            // Key just activated — start recording
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

        // If key is off, nothing to do
        if !keyOn { return nil }

        // Enter recording mode once held past tap threshold
        if !recording {
            if transitions.isEmpty {
                transitions = [Date()]
            }
            if let first = transitions.first, Date().timeIntervalSince(first) >= recordThresholdSec {
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
        // If the key is still physically held, suppress until released
        suppressed = isKeyOn
    }

    // MARK: - Modifier double-tap monitoring (Option = play, Control = cancel)

    private func startModifierMonitor() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierEvent(event)
        }
        if let global { keyMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierEvent(event)
            return event
        }
        if let local { keyMonitors.append(local) }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let now = Date()

        // Option key double-tap → play
        let optionDown = flags.contains(.option)
        if optionDown && !optionWasDown {
            // Option key pressed
            optionTaps.append(now)
            optionTaps = optionTaps.filter { now.timeIntervalSince($0) < tapWindowSec }
            if optionTaps.count >= 2 {
                optionTaps.removeAll()
                pendingPlay = true
            }
        }
        optionWasDown = optionDown

        // Control key double-tap → cancel
        let controlDown = flags.contains(.control)
        if controlDown && !controlWasDown {
            controlTaps.append(now)
            controlTaps = controlTaps.filter { now.timeIntervalSince($0) < tapWindowSec }
            if controlTaps.count >= 2 {
                controlTaps.removeAll()
                pendingCancel = true
            }
        }
        controlWasDown = controlDown
    }

    // MARK: - Custom key monitoring

    private func startKeyMonitor() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        if let global { keyMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        if let local { keyMonitors.append(local) }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        manualKeyDown = nil

        if event.type == .flagsChanged {
            guard event.keyCode == targetKeyCode else { return }
            customKeyDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(targetModifiers)
            return
        }

        guard event.keyCode == targetKeyCode else { return }

        if !targetModifiers.isEmpty {
            let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard current == targetModifiers else {
                customKeyDown = false
                return
            }
        }

        if event.type == .keyDown && !event.isARepeat {
            customKeyDown.toggle()
        }
    }

    private func stopKeyMonitor() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors.removeAll()
    }

    // MARK: - Key string parsing

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
