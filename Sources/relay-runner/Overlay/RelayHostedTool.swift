import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RelayHostedToolError: Error {
    case message(String)
}

enum RelayHostedToolResult {
    case success([[String: Any]])
    case failure(String)
}

enum RelayHostedTool {
    static func requiredPermission(for tool: String) -> PermissionKind? {
        switch tool {
        case "click", "type", "key", "scroll":
            return .accessibility
        case "screenshot":
            return .screenRecording
        default:
            return nil
        }
    }

    static func isMissingPermissionFailure(_ message: String, for permission: PermissionKind) -> Bool {
        switch permission {
        case .accessibility:
            return message.contains("Accessibility permission is not granted to Relay Runner")
        case .screenRecording:
            return message.contains("Screen Recording permission is not granted to Relay Runner")
        case .microphone, .inputMonitoring:
            return false
        }
    }

    static func perform(tool: String, arguments: [String: Any]) async -> RelayHostedToolResult {
        do {
            switch tool {
            case "click":
                return .success(try performClick(arguments: arguments))
            case "type":
                return .success(try performType(arguments: arguments))
            case "key":
                return .success(try performKey(arguments: arguments))
            case "scroll":
                return .success(try performScroll(arguments: arguments))
            case "screenshot":
                return .success(try await performScreenshot(arguments: arguments))
            default:
                return .failure("Relay Runner does not host a tool named '\(tool)'.")
            }
        } catch let error as RelayHostedToolError {
            switch error {
            case .message(let message): return .failure(message)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Input

    private static func performClick(arguments: [String: Any]) throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else {
            throw RelayHostedToolError.message("click requires integer x and y arguments.")
        }
        let buttonName = arguments["button"] as? String ?? "left"
        let doubleClick = arguments["double"] as? Bool ?? false
        let modifiers = arguments["modifiers"] as? [String] ?? []

        let verb = buttonName == "right" ? "right-click" : (buttonName == "middle" ? "middle-click" : "click")
        try ensureAccessibility(purpose: arguments["purpose"] as? String ?? "\(verb) at (\(x), \(y))")

        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch buttonName {
        case "right":
            mouseButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case "middle":
            mouseButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        default:
            mouseButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        }

        let point = pointFromPixel(x: x, y: y)
        let flags = flagsFromModifiers(modifiers)
        let clickCount = doubleClick ? 2 : 1
        for tap in 1...clickCount {
            try postMouseEvent(type: downType, point: point, button: mouseButton, flags: flags, clickCount: tap)
            try postMouseEvent(type: upType, point: point, button: mouseButton, flags: flags, clickCount: tap)
        }

        return [["type": "text", "text": "Clicked at (\(x), \(y))\(doubleClick ? " (double)" : "")."]]
    }

    private static func performType(arguments: [String: Any]) throws -> [[String: Any]] {
        guard let text = arguments["text"] as? String else {
            throw RelayHostedToolError.message("type requires a string text argument.")
        }
        try ensureAccessibility(purpose: arguments["purpose"] as? String ?? "type text into the focused field")

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw RelayHostedToolError.message("CGEvent creation failed for typing.")
        }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        return [["type": "text", "text": "Typed \(utf16.count) character(s)."]]
    }

    private static func performKey(arguments: [String: Any]) throws -> [[String: Any]] {
        guard let combo = arguments["combo"] as? String else {
            throw RelayHostedToolError.message("key requires a string combo argument.")
        }
        try ensureAccessibility(purpose: arguments["purpose"] as? String ?? "press \(combo)")

        let parts = combo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var modifiers: [String] = []
        var keyName: String?
        for part in parts {
            if ["cmd", "shift", "option", "control"].contains(part) {
                modifiers.append(part)
            } else {
                keyName = part
            }
        }
        guard let keyName, let virtualKey = virtualKeyForName(keyName) else {
            throw RelayHostedToolError.message("Unknown key '\(keyName ?? "")' in combo '\(combo)'. Supported names: return, escape, tab, space, delete, left, right, up, down, home, end, pageup, pagedown, a-z, 0-9, F1-F12.")
        }
        let flags = flagsFromModifiers(modifiers)

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else {
            throw RelayHostedToolError.message("CGEvent creation failed for key event.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        return [["type": "text", "text": "Pressed '\(combo)'."]]
    }

    private static func performScroll(arguments: [String: Any]) throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int, let dy = arguments["dy"] as? Int else {
            throw RelayHostedToolError.message("scroll requires integer x, y, and dy arguments.")
        }
        let dx = arguments["dx"] as? Int ?? 0
        try ensureAccessibility(purpose: arguments["purpose"] as? String ?? "scroll at (\(x), \(y))")

        let point = pointFromPixel(x: x, y: y)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }

        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .line,
                                  wheelCount: 2,
                                  wheel1: Int32(dy),
                                  wheel2: Int32(dx),
                                  wheel3: 0) else {
            throw RelayHostedToolError.message("CGEvent creation failed for scroll event.")
        }
        event.post(tap: .cghidEventTap)

        return [["type": "text", "text": "Scrolled at (\(x), \(y)) by dx=\(dx) dy=\(dy)."]]
    }

    private static func ensureAccessibility(purpose: String) throws {
        if AXIsProcessTrusted() { return }

        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        if pollUntilGranted(check: { AXIsProcessTrusted() }, timeout: 4.0) {
            return
        }

        throw RelayHostedToolError.message("""
            Could not perform the action. Accessibility permission is not granted to Relay Runner.

            To \(purpose), grant Accessibility to **Relay Runner**:

            1. Open System Settings -> Privacy & Security -> Accessibility
            2. Toggle on Relay Runner
            3. Try the action again

            Codex, Claude, Terminal, and other agent hosts do not need this permission for Relay Actions.
            """)
    }

    // MARK: - Screenshot

    private static func performScreenshot(arguments: [String: Any]) async throws -> [[String: Any]] {
        let displayIndex = arguments["display_index"] as? Int ?? 0
        try ensureScreenRecording(purpose: arguments["purpose"] as? String ?? "take a screenshot")

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw RelayHostedToolError.message("""
                Could not capture the screen. macOS reported Screen Recording as granted to Relay Runner, but ScreenCaptureKit still failed. Quit and relaunch Relay Runner, then retry.

                Underlying error: \(error.localizedDescription)
                """)
        }

        guard !content.displays.isEmpty else {
            throw RelayHostedToolError.message("No displays detected.")
        }
        guard displayIndex >= 0, displayIndex < content.displays.count else {
            throw RelayHostedToolError.message("display_index \(displayIndex) out of range (\(content.displays.count) display(s) connected)")
        }

        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let (configWidth, configHeight) = nativePixelDimensions(forDisplayID: display.displayID)
            ?? (display.width, display.height)

        let config = SCStreamConfiguration()
        config.width = configWidth
        config.height = configHeight
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw RelayHostedToolError.message("Screenshot capture failed: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw RelayHostedToolError.message("Failed to encode screenshot as PNG.")
        }

        return [
            [
                "type": "image",
                "data": pngData.base64EncodedString(),
                "mimeType": "image/png",
            ],
            [
                "type": "text",
                "text": "Captured display \(displayIndex) at \(configWidth)x\(configHeight) pixels. Click/scroll coordinates are in this same pixel space.",
            ],
        ]
    }

    private static func ensureScreenRecording(purpose: String) throws {
        if CGPreflightScreenCaptureAccess() { return }

        _ = CGRequestScreenCaptureAccess()

        if pollUntilGranted(check: { CGPreflightScreenCaptureAccess() }, timeout: 4.0) {
            return
        }

        throw RelayHostedToolError.message("""
            Could not capture the screen. Screen Recording permission is not granted to Relay Runner.

            To \(purpose), grant Screen Recording to **Relay Runner**:

            1. Open System Settings -> Privacy & Security -> Screen Recording
            2. Toggle on Relay Runner
            3. Quit and relaunch Relay Runner if macOS asks
            4. Try the screenshot again

            Codex, Claude, Terminal, and other agent hosts do not need this permission for Relay Vision.
            """)
    }

    // MARK: - Helpers

    private static func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton, flags: CGEventFlags, clickCount: Int) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw RelayHostedToolError.message("CGEvent creation failed for mouse event.")
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
    }

    private static func screenForPixel(x: Int, y: Int) -> NSScreen? {
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            let frame = screen.frame
            let pxX = Int(frame.origin.x * scale)
            let pxYBottom = Int(frame.origin.y * scale)
            let pxW = Int(frame.size.width * scale)
            let pxH = Int(frame.size.height * scale)
            let primaryHeight = NSScreen.screens.first.map { Int($0.frame.size.height * $0.backingScaleFactor) } ?? 0
            let pxYTop = primaryHeight - pxYBottom - pxH

            if x >= pxX && x < pxX + pxW && y >= pxYTop && y < pxYTop + pxH {
                return screen
            }
        }
        return nil
    }

    private static func pointFromPixel(x: Int, y: Int) -> CGPoint {
        let scale = screenForPixel(x: x, y: y)?.backingScaleFactor ?? 1.0
        return CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
    }

    private static func nativePixelDimensions(forDisplayID id: CGDirectDisplayID) -> (Int, Int)? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let screenID = screen.deviceDescription[key] as? CGDirectDisplayID else { continue }
            if screenID == id {
                let scale = screen.backingScaleFactor
                let w = Int((screen.frame.width * scale).rounded())
                let h = Int((screen.frame.height * scale).rounded())
                return (w, h)
            }
        }
        return nil
    }

    private static func flagsFromModifiers(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    private static func virtualKeyForName(_ name: String) -> CGKeyCode? {
        switch name {
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc": return 0x35
        case "left": return 0x7B
        case "right": return 0x7C
        case "down": return 0x7D
        case "up": return 0x7E
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "9": return 0x19
        case "7": return 0x1A
        case "8": return 0x1C
        case "0": return 0x1D
        case "o": return 0x1F
        case "u": return 0x20
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "k": return 0x28
        case "n": return 0x2D
        case "m": return 0x2E
        case "f1": return 0x7A
        case "f2": return 0x78
        case "f3": return 0x63
        case "f4": return 0x76
        case "f5": return 0x60
        case "f6": return 0x61
        case "f7": return 0x62
        case "f8": return 0x64
        case "f9": return 0x65
        case "f10": return 0x6D
        case "f11": return 0x67
        case "f12": return 0x6F
        default: return nil
        }
    }

    private static func pollUntilGranted(check: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return check()
    }
}
