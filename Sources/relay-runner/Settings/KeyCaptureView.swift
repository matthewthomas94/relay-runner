import SwiftUI
import AppKit

struct KeyCaptureView: View {
    let label: String
    @Binding var value: String

    @State private var isCapturing = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            KeyCaptureField(value: $value, isCapturing: $isCapturing)
                .frame(width: 150, height: 24)
            if value.lowercased() != "caps lock" && !value.isEmpty {
                Button {
                    value = "Caps Lock"
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - NSViewRepresentable

private struct KeyCaptureField: NSViewRepresentable {
    @Binding var value: String
    @Binding var isCapturing: Bool

    func makeNSView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onKeyCapture = { key in
            value = key
            isCapturing = false
        }
        view.onCancel = {
            isCapturing = false
        }
        view.displayText = value.isEmpty ? "Caps Lock" : value
        return view
    }

    func updateNSView(_ nsView: KeyInputView, context: Context) {
        if isCapturing && !nsView.isCaptureActive {
            nsView.startCapture()
        } else if !isCapturing {
            nsView.stopCapture()
            nsView.displayText = value.isEmpty ? "Caps Lock" : value
            nsView.isHighlighted = false
            nsView.needsDisplay = true
        }
    }
}

// MARK: - Key input view

private final class KeyInputView: NSView {
    var onKeyCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var displayText = ""
    var isHighlighted = false
    private(set) var isCaptureActive = false

    private var localMonitor: Any?
    private var globalMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        if !isCaptureActive {
            startCapture()
        }
    }

    func startCapture() {
        guard !isCaptureActive else { return }
        isCaptureActive = true
        isHighlighted = true
        displayText = "Press a key\u{2026}"
        needsDisplay = true

        // MenuBarExtra apps may not be active — force activation so the
        // local monitor can receive key events in the Settings window.
        NSApp.activate(ignoringOtherApps: true)

        // Local monitor: fires when this app is active, can consume events
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isCaptureActive else { return event }
            if self.handleCapturedEvent(event) { return nil }
            return event
        }

        // Global monitor: backup for when the app isn't frontmost
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isCaptureActive else { return }
            _ = self.handleCapturedEvent(event)
        }

        NSLog("[KeyCapture] Capture started, monitors installed")
    }

    func stopCapture() {
        guard isCaptureActive else { return }
        isCaptureActive = false
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    @discardableResult
    private func handleCapturedEvent(_ event: NSEvent) -> Bool {
        // Escape cancels
        if event.keyCode == 53 {
            stopCapture()
            onCancel?()
            return true
        }

        // Backspace resets to Caps Lock
        if event.keyCode == 51 {
            stopCapture()
            onKeyCapture?("Caps Lock")
            return true
        }

        let key = Self.formatKey(event)
        guard !key.isEmpty else { return false }

        NSLog("[KeyCapture] Captured: \(key)")
        stopCapture()
        onKeyCapture?(key)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isHighlighted
            ? .controlAccentColor.withAlphaComponent(0.15)
            : .controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.fill()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isHighlighted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let str = NSAttributedString(string: displayText, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        str.draw(at: origin)
    }

    // MARK: - Key formatting (matches CapsLockGesture.parseKeyString)

    static func formatKey(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags

        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Cmd") }

        let keyName: String
        switch event.keyCode {
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99:  keyName = "F3"
        case 118: keyName = "F4"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        case 36:  keyName = "Return"
        case 48:  keyName = "Tab"
        case 49:  keyName = "Space"
        default:
            keyName = event.charactersIgnoringModifiers?.uppercased() ?? ""
        }

        if !keyName.isEmpty {
            parts.append(keyName)
        }

        return parts.joined(separator: "+")
    }

    deinit {
        stopCapture()
    }
}
