import AppKit
import Foundation

struct BoardHotkeyGesture {
    static let defaultDoubleTapWindow: TimeInterval = 0.45

    private let doubleTapWindow: TimeInterval
    private var shiftDown = false
    private var cleanShiftTap = false
    private var tapTimes: [Date] = []

    init(doubleTapWindow: TimeInterval = Self.defaultDoubleTapWindow) {
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func handleFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags, at now: Date = Date()) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShiftDown = flags.contains(.shift)
        let hasOnlyShift = flags.subtracting([.shift, .capsLock]).isEmpty

        if isShiftDown {
            if !shiftDown {
                shiftDown = true
                cleanShiftTap = hasOnlyShift
            } else if !hasOnlyShift {
                cleanShiftTap = false
            }
            return false
        }

        guard shiftDown else {
            if !flags.subtracting(.capsLock).isEmpty {
                tapTimes.removeAll()
            }
            return false
        }

        let completedCleanTap = cleanShiftTap
        shiftDown = false
        cleanShiftTap = false

        guard completedCleanTap else {
            tapTimes.removeAll()
            return false
        }

        tapTimes.append(now)
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) <= doubleTapWindow }
        if tapTimes.count >= 2 {
            tapTimes.removeAll()
            return true
        }
        return false
    }

    mutating func handleKeyDown() {
        if shiftDown {
            cleanShiftTap = false
        }
        tapTimes.removeAll()
    }
}
