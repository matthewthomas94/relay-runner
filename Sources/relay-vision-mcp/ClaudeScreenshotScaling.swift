import CoreGraphics
import Foundation
import ImageIO

// Claude Code re-encodes MCP images to fit 2000x2000 (verified in 2.1.239), so
// coordinates read off a larger native-pixel screenshot drift. For
// `claude-code` clients this helper downscales to a known size and states the
// scale; relay-actions maps click/scroll x/y back to native pixels with the
// `screenshot_scale` the model passes. The two helpers are separate processes,
// so the scale travels through the model instead of shared state. Other clients
// never reach this code and keep the app's native-pixel result byte for byte.
enum ClaudeScreenshotScaling {
    static let maxLongEdge = 2000

    /// Image pixels per native pixel, floored to the 6 decimals the result
    /// states, so the stated value is exactly the one used to resize.
    static func scale(nativeWidth: Int, nativeHeight: Int) -> Double {
        let longEdge = max(nativeWidth, nativeHeight)
        guard longEdge > maxLongEdge else { return 1 }
        return (Double(maxLongEdge) / Double(longEdge) * 1_000_000).rounded(.down) / 1_000_000
    }

    static func imageSize(nativeWidth: Int, nativeHeight: Int, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((Double(nativeWidth) * scale).rounded())),
         max(1, Int((Double(nativeHeight) * scale).rounded())))
    }

    static func formatted(_ scale: Double) -> String {
        String(format: "%.6f", scale)
    }

    /// Replaces the app's native-pixel screenshot content with a Claude-sized
    /// image and a text item stating the scale.
    static func downscale(content: [[String: Any]], displayIndex: Int) throws -> [[String: Any]] {
        guard let item = content.first(where: { $0["type"] as? String == "image" }),
              let base64 = item["data"] as? String,
              let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let native = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MCPToolError(message: "Could not decode the screenshot to size it for Claude Code.")
        }

        let scale = scale(nativeWidth: native.width, nativeHeight: native.height)
        let size = imageSize(nativeWidth: native.width, nativeHeight: native.height, scale: scale)
        var imageItem = item
        if scale < 1 {
            imageItem["data"] = try resizedPNG(native, width: size.width, height: size.height).base64EncodedString()
            imageItem["mimeType"] = "image/png"
        }

        let stated = formatted(scale)
        return [
            imageItem,
            [
                "type": "text",
                "text": "Captured display \(displayIndex) at \(native.width)x\(native.height) native pixels, "
                    + "returned at \(size.width)x\(size.height) (screenshot_scale \(stated)). "
                    + "Read click/scroll x/y off this image and pass screenshot_scale \(stated); "
                    + "Relay Actions maps them back to native pixels.",
            ],
        ]
    }

    private static func resizedPNG(_ image: CGImage, width: Int, height: Int) throws -> Data {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MCPToolError(message: "Could not allocate the Claude-sized screenshot.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let output = NSMutableData()
        guard let resized = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw MCPToolError(message: "Could not encode the Claude-sized screenshot.")
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MCPToolError(message: "Could not encode the Claude-sized screenshot.")
        }
        return output as Data
    }
}
