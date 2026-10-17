import AppKit
import Foundation

enum SessionSwitchDirection: Equatable {
    case next
    case previous
}

/// Shift+Right / Shift+Left switch the voice target between open sessions
/// (RR-408). Detection is passive: the monitors cannot consume the keypress,
/// so the frontmost app still receives it.
enum SessionSwitchGesture {
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124

    /// Arrow keys carry `.numericPad` and `.function` on their own, and a
    /// held Caps Lock changes no chord, so none of them count as modifiers.
    private static let incidentalFlags: NSEvent.ModifierFlags = [.numericPad, .function, .capsLock]

    static func direction(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> SessionSwitchDirection? {
        guard !isRepeat else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(incidentalFlags)
        guard flags == .shift else { return nil }
        switch keyCode {
        case rightArrowKeyCode: return .next
        case leftArrowKeyCode: return .previous
        default: return nil
        }
    }
}

/// What the notch says after a switch attempt. Only a switch that happened is
/// ever claimed as one.
enum SessionSwitchNotice: Equatable {
    case switched(to: String)
    case nextRecording(to: String)
    case pending(to: String)

    static let displayDuration: TimeInterval = 2

    var label: String {
        switch self {
        case .switched(let name): return "Switched to · \(name)"
        case .nextRecording(let name): return "Next recording · \(name)"
        case .pending(let name): return "Switch pending · \(name)"
        }
    }
}

/// Cycles the live sessions in tab order and reports the honest outcome.
/// The switch itself goes through `focus` (`AppState.focusSessionTab`).
struct SessionSwitchCoordinator<ID: Hashable> {
    let liveIDs: () -> [ID]
    let currentID: () -> ID?
    let displayName: (ID) -> String?
    let focus: (ID) -> Void
    let isFocused: (ID) -> Bool
    let isPending: (ID) -> Bool
    let isRecording: () -> Bool

    /// The session after (or before) `current`, wrapping at both ends. Fewer
    /// than two live sessions has nothing to switch to.
    static func target(live: [ID], current: ID?, direction: SessionSwitchDirection) -> ID? {
        guard live.count > 1 else { return nil }
        guard let current, let index = live.firstIndex(of: current) else {
            return direction == .next ? live.first : live.last
        }
        let step = direction == .next ? 1 : live.count - 1
        return live[(index + step) % live.count]
    }

    func switchTarget(_ direction: SessionSwitchDirection) -> SessionSwitchNotice? {
        let recording = isRecording()
        guard let target = Self.target(live: liveIDs(), current: currentID(), direction: direction),
              let name = displayName(target) else { return nil }
        focus(target)
        if isFocused(target) {
            // The in-flight recording keeps the session it started with.
            return recording ? .nextRecording(to: name) : .switched(to: name)
        }
        return isPending(target) ? .pending(to: name) : nil
    }
}
