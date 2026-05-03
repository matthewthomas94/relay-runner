import AppKit
import CoreGraphics
import Foundation

// CGEvent posting tools: click, type, key, scroll.
//
// Coordinate contract: x/y inputs are in the SAME pixel space ScreenshotTool
// returns — i.e. NSScreen.frame × backingScaleFactor (the display's native
// pixel grid). CGEvent itself is in global display coordinates measured in
// points (top-left origin), so pointFromPixel() divides by the screen's
// backing scale factor before posting. On a single-display 1× setup pixels
// and points are identical; on Retina or mixed-DPI setups they aren't.
//
// Every tool here pre-flights AXIsProcessTrusted via PermissionPreflight
// before posting. The pre-flight speaks a TTS warning naming the parent app
// (Terminal / Warp / VS Code) the user must grant, since macOS attributes
// CGEvent posting to that app — not Relay Runner.

private func screenForPixel(x: Int, y: Int) -> NSScreen? {
    // Walk all screens, picking the one whose pixel-space frame contains the point.
    // Each NSScreen.frame is in points; multiplying by backingScaleFactor gives
    // the pixel-space rect. Origins are bottom-left in NSScreen coordinates.
    for screen in NSScreen.screens {
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        let pxX = Int(frame.origin.x * scale)
        let pxYBottom = Int(frame.origin.y * scale)
        let pxW = Int(frame.size.width * scale)
        let pxH = Int(frame.size.height * scale)

        // Convert to top-left-origin pixel coordinates relative to the global
        // coordinate system (CGEvent uses top-left). The primary screen's
        // top-left is (0, 0); other screens may be negative or offset.
        let primaryHeight = NSScreen.screens.first.map { Int($0.frame.size.height * $0.backingScaleFactor) } ?? 0
        let pxYTop = primaryHeight - pxYBottom - pxH

        if x >= pxX && x < pxX + pxW && y >= pxYTop && y < pxYTop + pxH {
            return screen
        }
    }
    return nil
}

private func pointFromPixel(x: Int, y: Int) -> CGPoint {
    // CGEvent expects global display coordinates in points (top-left origin).
    // Convert by dividing by the relevant screen's backing scale factor.
    let scale = screenForPixel(x: x, y: y)?.backingScaleFactor ?? 1.0
    return CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
}

// MARK: - Click

struct ClickTool: MCPTool {
    let name = "click"
    let description = """
        Post a mouse click at the given pixel coordinates. x/y are in the SAME pixel \
        space as the most recent `screenshot` tool output — read the coordinate directly \
        off the screenshot image and pass it through. `button` defaults to 'left'. \
        `modifiers` is an optional array of any of: 'cmd', 'shift', 'option', 'control'. \
        Call `propose_action` first for any state-changing click so the user can confirm \
        AND so the permission pre-flight (if needed) names the action accurately.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x": ["type": "integer", "description": "Pixel X coordinate."],
                "y": ["type": "integer", "description": "Pixel Y coordinate."],
                "button": [
                    "type": "string",
                    "enum": ["left", "right", "middle"],
                    "description": "Mouse button to click. Default: left.",
                ],
                "double": [
                    "type": "boolean",
                    "description": "If true, post a double-click. Default: false.",
                ],
                "modifiers": [
                    "type": "array",
                    "items": ["type": "string", "enum": ["cmd", "shift", "option", "control"]],
                    "description": "Modifier keys to hold during the click.",
                ],
            ],
            "required": ["x", "y"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int else {
            throw MCPToolError(message: "click requires integer x and y arguments.")
        }
        let buttonName = arguments["button"] as? String ?? "left"
        let doubleClick = arguments["double"] as? Bool ?? false
        let modifiers = (arguments["modifiers"] as? [String]) ?? []

        let verb = (buttonName == "right" ? "right-click" : (buttonName == "middle" ? "middle-click" : "click"))
        switch PermissionPreflight.ensureAccessibility(fallbackPurpose: "\(verb) at (\(x), \(y))") {
        case .granted: break
        case .stillMissing(let message): throw MCPToolError(message: message)
        }

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

    private func postMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton, flags: CGEventFlags, clickCount: Int) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw MCPToolError(message: "CGEvent creation failed for mouse event.")
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Type text

struct TypeTool: MCPTool {
    let name = "type"
    let description = """
        Type text into whatever currently has keyboard focus. Use after `click` if you need to \
        focus a field first. Special characters supported. Does NOT post Return at the end — \
        use the `key` tool with combo='return' for that.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Text to type."],
            ],
            "required": ["text"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let text = arguments["text"] as? String else {
            throw MCPToolError(message: "type requires a string text argument.")
        }
        // Don't quote the text in the fallback purpose — it could be a password
        // that the user is having Claude type into a focused field.
        switch PermissionPreflight.ensureAccessibility(fallbackPurpose: "type text into the focused field") {
        case .granted: break
        case .stillMissing(let message): throw MCPToolError(message: message)
        }
        // CGEvent's keyboardSetUnicodeString accepts arbitrary UTF-16 strings —
        // we don't need to map to virtual keycodes for individual chars. This
        // also handles emoji, punctuation, accented characters etc.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw MCPToolError(message: "CGEvent creation failed for typing.")
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
}

// MARK: - Key combo

struct KeyTool: MCPTool {
    let name = "key"
    let description = """
        Press a single key or key combination, e.g. 'return', 'escape', 'tab', 'cmd+a', \
        'cmd+shift+t', 'control+option+left'. Modifier keys: cmd, shift, option, control.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "combo": [
                    "type": "string",
                    "description": "Key combo, e.g. 'return', 'cmd+a', 'cmd+shift+left'.",
                ],
            ],
            "required": ["combo"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let combo = arguments["combo"] as? String else {
            throw MCPToolError(message: "key requires a string combo argument.")
        }
        switch PermissionPreflight.ensureAccessibility(fallbackPurpose: "press \(combo)") {
        case .granted: break
        case .stillMissing(let message): throw MCPToolError(message: message)
        }
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
            throw MCPToolError(message: "Unknown key '\(keyName ?? "")' in combo '\(combo)'. Supported names: return, escape, tab, space, delete, left, right, up, down, home, end, pageup, pagedown, a–z, 0–9, F1–F12.")
        }
        let flags = flagsFromModifiers(modifiers)

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else {
            throw MCPToolError(message: "CGEvent creation failed for key event.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        return [["type": "text", "text": "Pressed '\(combo)'."]]
    }
}

// MARK: - Scroll

struct ScrollTool: MCPTool {
    let name = "scroll"
    let description = """
        Post a scroll wheel event at pixel coordinates (x, y). `dx` and `dy` are line counts \
        (positive dy = scroll up / content moves down; negative dy = scroll down).
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "x": ["type": "integer"],
                "y": ["type": "integer"],
                "dx": ["type": "integer", "description": "Horizontal scroll lines. Default: 0."],
                "dy": ["type": "integer", "description": "Vertical scroll lines. Positive = up."],
            ],
            "required": ["x", "y", "dy"],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        guard let x = arguments["x"] as? Int, let y = arguments["y"] as? Int, let dy = arguments["dy"] as? Int else {
            throw MCPToolError(message: "scroll requires integer x, y, and dy arguments.")
        }
        let dx = arguments["dx"] as? Int ?? 0

        switch PermissionPreflight.ensureAccessibility(fallbackPurpose: "scroll at (\(x), \(y))") {
        case .granted: break
        case .stillMissing(let message): throw MCPToolError(message: message)
        }

        // First move the cursor so scroll is targeted at the right window — apps that gate
        // scroll by hover (e.g. Safari nested scroll containers) need this.
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
            throw MCPToolError(message: "CGEvent creation failed for scroll event.")
        }
        event.post(tap: .cghidEventTap)

        return [["type": "text", "text": "Scrolled at (\(x), \(y)) by dx=\(dx) dy=\(dy)."]]
    }
}

// MARK: - Helpers

private func flagsFromModifiers(_ modifiers: [String]) -> CGEventFlags {
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

// Subset of macOS virtual keycodes. Covers the keys Claude is realistically going to press
// for UAT and dashboard navigation. Letter/number keys map to standard US layout — for other
// layouts, Claude should use the `type` tool instead.
private func virtualKeyForName(_ name: String) -> CGKeyCode? {
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
