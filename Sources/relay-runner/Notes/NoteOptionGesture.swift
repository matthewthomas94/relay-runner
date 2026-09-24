import AppKit
import Foundation

/// Recognizes two clean Option presses and releases without consuming keyboard events.
struct NoteOptionDoubleTap {
    private let tapWindow: TimeInterval = 0.6
    private let holdLimit: TimeInterval = 0.5
    private var pressedAt: TimeInterval?
    private var firstReleasedAt: TimeInterval?
    private var invalidPress = false

    mutating func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let now = event.timestamp
        if event.type == .keyDown {
            reset()
            invalidPress = flags.contains(.option)
            return false
        }
        guard event.type == .flagsChanged else { return false }
        guard event.keyCode == 58 || event.keyCode == 61 else {
            if !flags.subtracting([.option, .capsLock]).isEmpty { reset() }
            return false
        }
        guard flags.subtracting([.option, .capsLock]).isEmpty else {
            reset()
            return false
        }
        if flags.contains(.option) {
            if pressedAt == nil {
                if let firstReleasedAt, now - firstReleasedAt > tapWindow {
                    self.firstReleasedAt = nil
                }
                pressedAt = now
                invalidPress = false
            }
            return false
        }
        guard let pressedAt else { return false }
        self.pressedAt = nil
        guard !invalidPress, now - pressedAt <= holdLimit else {
            reset()
            return false
        }
        if let firstReleasedAt, now - firstReleasedAt <= tapWindow {
            reset()
            return true
        }
        firstReleasedAt = now
        return false
    }

    mutating func reset() {
        pressedAt = nil
        firstReleasedAt = nil
        invalidPress = false
    }
}

/// Keeps Workspace's Shift gesture available while the voice gesture monitor is stopped.
struct NoteShiftDoubleTap {
    private let tapWindow: TimeInterval = BoardHotkeyGesture.defaultDoubleTapWindow
    private let holdLimit: TimeInterval = 0.5
    private var pressedAt: TimeInterval?
    private var pressedKeyCode: UInt16?
    private var firstReleasedAt: TimeInterval?

    mutating func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            reset()
            return false
        }
        guard event.type == .flagsChanged else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 56 || event.keyCode == 60 else {
            if !flags.subtracting([.shift, .capsLock]).isEmpty { reset() }
            return false
        }
        guard flags.subtracting([.shift, .capsLock]).isEmpty else {
            reset()
            return false
        }
        if flags.contains(.shift) {
            if let pressedKeyCode, pressedKeyCode != event.keyCode {
                reset()
            } else if pressedAt == nil {
                if let firstReleasedAt, event.timestamp - firstReleasedAt > tapWindow {
                    self.firstReleasedAt = nil
                }
                pressedAt = event.timestamp
                pressedKeyCode = event.keyCode
            }
            return false
        }
        guard let pressedAt, pressedKeyCode == event.keyCode else {
            reset()
            return false
        }
        self.pressedAt = nil
        pressedKeyCode = nil
        guard event.timestamp - pressedAt <= holdLimit else {
            reset()
            return false
        }
        if let firstReleasedAt, event.timestamp - firstReleasedAt <= tapWindow {
            reset()
            return true
        }
        firstReleasedAt = event.timestamp
        return false
    }

    mutating func reset() {
        pressedAt = nil
        pressedKeyCode = nil
        firstReleasedAt = nil
    }
}

/// Owns only note-mode Option pause and Shift Workspace gestures.
final class NoteOptionGesture {
    typealias GlobalInstaller = (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    typealias LocalInstaller = (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?

    private var recognizer = NoteOptionDoubleTap()
    private var workspaceRecognizer = NoteShiftDoubleTap()
    private let globalInstaller: GlobalInstaller
    private let remover: (Any) -> Void
    private let onToggle: () -> Void
    private let onWorkspaceToggle: () -> Void
    private var monitors: [Any] = []
    private var hasGlobalMonitor = false
    private var retry: DispatchWorkItem?
    private var stopped = false

    init(
        globalInstaller: @escaping GlobalInstaller = { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
        localInstaller: @escaping LocalInstaller = { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
        remover: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        onToggle: @escaping () -> Void,
        onWorkspaceToggle: @escaping () -> Void
    ) {
        self.globalInstaller = globalInstaller
        self.remover = remover
        self.onToggle = onToggle
        self.onWorkspaceToggle = onWorkspaceToggle
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let local = localInstaller(mask, { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
        installGlobalMonitor()
    }

    private func installGlobalMonitor() {
        guard !stopped, !hasGlobalMonitor else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = globalInstaller(mask, { [weak self] event in self?.handle(event) }) {
            monitors.append(global)
            hasGlobalMonitor = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.installGlobalMonitor()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func handle(_ event: NSEvent) {
        guard !stopped else { return }
        if recognizer.handle(event) { onToggle() }
        if workspaceRecognizer.handle(event) { onWorkspaceToggle() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        retry?.cancel()
        retry = nil
        recognizer.reset()
        workspaceRecognizer.reset()
        for monitor in monitors { remover(monitor) }
        monitors.removeAll()
    }

    deinit { stop() }
}
