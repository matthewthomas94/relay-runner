import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ScreenshotTool: MCPTool {
    let name = "screenshot"
    let description = """
        Capture a screenshot of a connected display and return it as a base64-encoded PNG. \
        Defaults to the primary display. The returned image's pixel dimensions match \
        NSScreen.frame × backingScaleFactor (i.e. the display's native pixels). Coordinates \
        consumed by `click`, `scroll`, etc. are in this same pixel space — Claude can read \
        a coordinate directly off the image and pass it through.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "display_index": [
                    "type": "integer",
                    "description": "Zero-based index into the list of connected displays. Default: 0 (primary).",
                ],
            ],
            "required": [],
        ]
    }

    func call(arguments: [String: Any]) async throws -> [[String: Any]] {
        let displayIndex = arguments["display_index"] as? Int ?? 0

        // Pre-flight: speak a warning and surface the OS prompt before we touch
        // SCShareableContent, so the user knows what's coming and which app to
        // grant. ScreenshotTool used to call CGRequestScreenCaptureAccess inline
        // here, which fired the OS dialog with no warning.
        switch PermissionPreflight.ensureScreenRecording(fallbackPurpose: "take a screenshot") {
        case .granted: break
        case .stillMissing(let message): throw MCPToolError(message: message)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // SCShareableContent failed despite the preflight saying we were
            // granted — usually means the grant only takes effect on relaunch.
            // Reuse the same parent-app message the preflight would emit.
            let parent = ParentProcess.detectTerminal()?.displayName
                ?? "the app you launched `claude` from"
            throw MCPToolError(message: """
                Could not capture the screen. macOS reported permission as granted, but \
                SCShareableContent still failed. This is the well-known "grant doesn't \
                take effect until relaunch" behaviour for Screen Recording on a \
                long-running process. Quit and relaunch **\(parent)**, then restart your \
                `claude` session.

                Underlying error: \(error.localizedDescription)
                """)
        }

        guard !content.displays.isEmpty else {
            throw MCPToolError(message: "No displays detected.")
        }

        guard displayIndex >= 0, displayIndex < content.displays.count else {
            throw MCPToolError(message: "display_index \(displayIndex) out of range (\(content.displays.count) display(s) connected)")
        }

        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // SCDisplay.width/height return the *active display mode* dimensions,
        // which on a "scaled" mode (e.g. MacBook Pro at "More Space") are the
        // logical-points dimensions, NOT the underlying retina pixels. If we
        // hand those numbers to SCStreamConfiguration we get a downscaled
        // image — and the input tools' coordinate math (which divides input by
        // backingScaleFactor on the assumption that input is native pixels)
        // ends up off by exactly that scale factor.
        //
        // Source the dimensions from NSScreen.frame × backingScaleFactor
        // instead — that's the actual pixel grid the system renders at, and
        // matches what ClickTool's pointFromPixel() reverses.
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
            throw MCPToolError(message: "Screenshot capture failed: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw MCPToolError(message: "Failed to encode screenshot as PNG.")
        }

        let base64 = pngData.base64EncodedString()

        return [
            [
                "type": "image",
                "data": base64,
                "mimeType": "image/png",
            ],
            // Send dimensions as a sibling text block so the model gets the pixel bounds without
            // having to inspect the image — useful for grounding click coordinates.
            [
                "type": "text",
                "text": "Captured display \(displayIndex) at \(configWidth)×\(configHeight) pixels. Click/scroll coordinates are in this same pixel space.",
            ],
        ]
    }

    /// Find the NSScreen for a CGDirectDisplayID and return its native pixel
    /// dimensions (frame × backingScaleFactor). Returns nil if no NSScreen
    /// matches — caller falls back to SCDisplay's reported dims.
    private func nativePixelDimensions(forDisplayID id: CGDirectDisplayID) -> (Int, Int)? {
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
}
