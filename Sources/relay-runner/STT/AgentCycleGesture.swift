import AppKit

/// Shift-Option switches to the next running agent and Shift-Control to the
/// previous one. The chord fires when its keys are released, and only when it
/// was pressed on its own: a key typed while the modifiers were down (such as
/// Shift-Option-K) or another modifier joining it makes it a shortcut instead.
struct AgentCycleGesture {
    enum Direction: Equatable {
        case forward
        case backward
    }

    private static let watched: NSEvent.ModifierFlags = [.shift, .option, .control, .command]

    private var chord: Direction?
    private var broken = false
    private var modifiersDown = false

    /// The chord is held right now, so its keys are not taps of their own.
    var isChordHeld: Bool { chord != nil && modifiersDown }

    static func direction(for flags: NSEvent.ModifierFlags) -> Direction? {
        switch flags.intersection(watched) {
        case [.shift, .option]: return .forward
        case [.shift, .control]: return .backward
        default: return nil
        }
    }

    /// Returns the direction to switch in when a clean chord is released.
    mutating func handleFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) -> Direction? {
        let flags = modifierFlags.intersection(Self.watched)
        guard !flags.isEmpty else {
            let completed = broken ? nil : chord
            chord = nil
            broken = false
            modifiersDown = false
            return completed
        }
        modifiersDown = true
        if let direction = Self.direction(for: flags) {
            if chord == nil {
                chord = direction
            } else if chord != direction {
                broken = true
            }
        } else if chord != nil, flags.contains(.command) || flags.isSuperset(of: [.option, .control]) {
            broken = true
        }
        return nil
    }

    mutating func handleKeyDown() {
        if modifiersDown { broken = true }
    }
}
