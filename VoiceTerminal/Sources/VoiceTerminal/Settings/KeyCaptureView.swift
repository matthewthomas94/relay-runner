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
            Button(isCapturing ? "Press a key\u{2026}" : (value.isEmpty ? "None" : value)) {
                isCapturing = true
            }
            .foregroundStyle(isCapturing ? .secondary : .primary)
            if !value.isEmpty && !isCapturing {
                Button(role: .destructive) {
                    value = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            KeyCaptureHelper(isCapturing: $isCapturing, value: $value)
        )
    }
}

// NSViewRepresentable to capture key events via NSEvent monitor
private struct KeyCaptureHelper: NSViewRepresentable {
    @Binding var isCapturing: Bool
    @Binding var value: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isCapturing && context.coordinator.monitor == nil {
            context.coordinator.startCapture()
        } else if !isCapturing && context.coordinator.monitor != nil {
            context.coordinator.stopCapture()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isCapturing: $isCapturing, value: $value)
    }

    class Coordinator {
        var monitor: Any?
        var isCapturing: Binding<Bool>
        var value: Binding<String>

        init(isCapturing: Binding<Bool>, value: Binding<String>) {
            self.isCapturing = isCapturing
            self.value = value
        }

        func startCapture() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                // Escape cancels
                if event.keyCode == 53 {
                    self.isCapturing.wrappedValue = false
                    return nil
                }

                // Backspace clears
                if event.keyCode == 51 {
                    self.value.wrappedValue = ""
                    self.isCapturing.wrappedValue = false
                    return nil
                }

                let keyName = self.formatKey(event)
                if !keyName.isEmpty {
                    self.value.wrappedValue = keyName
                    self.isCapturing.wrappedValue = false
                }
                return nil
            }
        }

        func stopCapture() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func formatKey(_ event: NSEvent) -> String {
            var parts: [String] = []
            let flags = event.modifierFlags

            if flags.contains(.control) { parts.append("Ctrl") }
            if flags.contains(.option) { parts.append("Alt") }
            if flags.contains(.shift) { parts.append("Shift") }
            if flags.contains(.command) { parts.append("Cmd") }

            // Map special keys
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
}
