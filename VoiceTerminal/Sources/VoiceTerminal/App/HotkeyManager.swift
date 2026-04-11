import AppKit
import Carbon.HIToolbox

/// Global hotkey registration using NSEvent monitors.
/// Does not require Accessibility permissions (events are observed, not consumed).
final class HotkeyManager {

    private var monitors: [Any] = []

    struct Hotkey {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    func register(config: ControlsConfig, onPlayPause: @escaping () -> Void, onSkip: @escaping () -> Void) {
        unregister()

        if let hotkey = parse(config.play_pause_key) {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == hotkey.keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotkey.modifiers {
                    onPlayPause()
                }
            }
            if let monitor { monitors.append(monitor) }
        }

        if let hotkey = parse(config.skip_key) {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == hotkey.keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotkey.modifiers {
                    onSkip()
                }
            }
            if let monitor { monitors.append(monitor) }
        }
    }

    func unregister() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    // MARK: - Key string parsing (matches KeyCaptureView output format)

    private func parse(_ keyString: String) -> Hotkey? {
        guard !keyString.isEmpty else { return nil }

        let parts = keyString.split(separator: "+").map(String.init)
        guard let keyName = parts.last else { return nil }

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

        guard let keyCode = keyCodeFor(keyName) else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCodeFor(_ name: String) -> UInt16? {
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
            // Single character — map via Carbon key code table
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
        unregister()
    }
}
