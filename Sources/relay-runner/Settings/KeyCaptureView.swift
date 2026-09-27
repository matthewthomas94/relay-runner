import SwiftUI
import AppKit

struct KeyCaptureView: View {
    let label: String
    var showsLabel = true
    @Binding var value: String

    @State private var isCapturing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsReset: Bool {
        value.lowercased() != "caps lock" && !value.isEmpty
    }

    var body: some View {
        HStack {
            if showsLabel {
                Text(label)
                Spacer()
            }
            KeyCaptureField(label: label, value: $value, isCapturing: $isCapturing)
                .frame(width: 150, height: 24)
            if showsReset {
                Button {
                    value = "Caps Lock"
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset \(label) to Caps Lock")
                .help("Reset \(label) to Caps Lock")
                .transition(.relayElement)
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: showsReset)
    }
}

// MARK: - NSViewRepresentable

private struct KeyCaptureField: NSViewRepresentable {
    let label: String
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
        view.accessibilityLabelText = label
        view.displayText = value.isEmpty ? "Caps Lock" : value
        view.committedDisplayText = view.displayText
        view.restoreCommittedDisplay()
        return view
    }

    func updateNSView(_ nsView: KeyInputView, context: Context) {
        nsView.accessibilityLabelText = label
        nsView.committedDisplayText = value.isEmpty ? "Caps Lock" : value
        if isCapturing && !nsView.isCaptureActive {
            nsView.startCapture()
        } else if !isCapturing {
            nsView.stopCapture()
            nsView.restoreCommittedDisplay()
        }
    }
}

// MARK: - Key input view

private final class KeyInputView: NSView {
    var onKeyCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var accessibilityLabelText = "Activation Key"
    var displayText = ""
    var committedDisplayText = ""
    var isHighlighted = false
    private(set) var isCaptureActive = false

    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// The key name swaps with the shared text motion; the field chrome
    /// eases between its resting and capturing colours.
    private let titleLabel = NSTextField(labelWithString: "")
    private var highlightAmount: CGFloat = 0
    private var highlightTarget: CGFloat = 0
    private var highlightTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = AppTypography.appKitFont(.body)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: 4, y: (bounds.height - height) / 2, width: max(0, bounds.width - 8), height: height)
    }

    override func mouseDown(with event: NSEvent) {
        activateCapture()
    }

    override func keyDown(with event: NSEvent) {
        if isCaptureActive {
            if handleCapturedEvent(event) { return }
        } else if event.keyCode == 36 || event.keyCode == 49 {
            activateCapture()
            return
        }
        super.keyDown(with: event)
    }

    private func activateCapture() {
        window?.makeFirstResponder(self)
        if !isCaptureActive {
            startCapture()
        }
    }

    func startCapture() {
        guard !isCaptureActive else { return }
        isCaptureActive = true
        isHighlighted = true
        displayText = "Press a key\u{2026}"
        refreshAppearance()

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

    func restoreCommittedDisplay() {
        displayText = committedDisplayText
        isHighlighted = false
        refreshAppearance()
    }

    private func refreshAppearance() {
        let color: NSColor = isHighlighted ? .secondaryLabelColor : .labelColor
        if titleLabel.stringValue != displayText || titleLabel.textColor != color {
            let text = displayText
            RelayLayerMotion.crossfade(titleLabel) {
                titleLabel.stringValue = text
                titleLabel.textColor = color
            }
        }
        animateHighlight(to: isHighlighted ? 1 : 0)
    }

    private func animateHighlight(to target: CGFloat) {
        guard target != highlightTarget else { return }
        highlightTarget = target
        highlightTimer?.invalidate()
        let start = highlightAmount
        let began = CACurrentMediaTime()
        let duration = RelayLayerMotion.reduceMotion ? 0.18 : RelayMotion.changeDuration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let fraction = CGFloat((CACurrentMediaTime() - began) / duration)
            self.highlightAmount = start + (target - start) * RelayMotion.changeCurve.progress(fraction)
            self.needsDisplay = true
            if fraction >= 1 {
                timer.invalidate()
                self.highlightTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    @discardableResult
    private func handleCapturedEvent(_ event: NSEvent) -> Bool {
        // Escape cancels
        if event.keyCode == 53 {
            stopCapture()
            restoreCommittedDisplay()
            onCancel?()
            return true
        }

        // Backspace resets to Caps Lock
        if event.keyCode == 51 {
            stopCapture()
            committedDisplayText = "Caps Lock"
            restoreCommittedDisplay()
            onKeyCapture?("Caps Lock")
            return true
        }

        let key = Self.formatKey(event)
        guard !key.isEmpty else { return false }

        NSLog("[KeyCapture] Captured: \(key)")
        stopCapture()
        committedDisplayText = key
        restoreCommittedDisplay()
        onKeyCapture?(key)
        return true
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        accessibilityLabelText
    }

    override func accessibilityValue() -> Any? {
        isCaptureActive ? "Press a key" : committedDisplayText
    }

    override func accessibilityPerformPress() -> Bool {
        activateCapture()
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = Self.blend(
            .controlBackgroundColor,
            SettingsSurfaceColor.neutralAccentNSColor.withAlphaComponent(0.15),
            highlightAmount
        )
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.fill()

        let stroke = Self.blend(
            .separatorColor,
            SettingsSurfaceColor.neutralAccentNSColor.withAlphaComponent(0.65),
            highlightAmount
        )
        stroke.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Mixes two colours resolved for the current drawing appearance.
    private static func blend(_ from: NSColor, _ to: NSColor, _ amount: CGFloat) -> NSColor {
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }
        guard let start = from.usingColorSpace(.sRGB), let end = to.usingColorSpace(.sRGB) else {
            return amount < 0.5 ? from : to
        }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
        return NSColor(
            srgbRed: mix(start.redComponent, end.redComponent),
            green: mix(start.greenComponent, end.greenComponent),
            blue: mix(start.blueComponent, end.blueComponent),
            alpha: mix(start.alphaComponent, end.alphaComponent)
        )
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
        highlightTimer?.invalidate()
        stopCapture()
    }
}
