import CoreGraphics
import ImageIO
import XCTest
@testable import relay_actions_mcp
@testable import relay_vision_mcp

// Claude Code downscales MCP images over 2000 px, so Claude screenshots are
// downscaled by relay-vision with a stated scale and relay-actions maps
// click/scroll x/y back to native pixels. Codex keeps native pixels.
// Nothing here reaches the app socket, so no real capture or click happens.
final class ClaudeScreenshotCoordinateTests: XCTestCase {
    private typealias Scaling = relay_vision_mcp.ClaudeScreenshotScaling
    private typealias Coordinates = relay_actions_mcp.ClaudeScreenshotCoordinates

    // MARK: - Scale

    func testScaleKeepsLongEdgeWithinClaudeLimit() {
        let cases: [(w: Int, h: Int, scale: String, iw: Int, ih: Int)] = [
            (3024, 1964, "0.661375", 2000, 1299), // 14" MacBook Pro Retina
            (3456, 2234, "0.578703", 2000, 1293), // 16" MacBook Pro Retina
            (5120, 2880, "0.390625", 2000, 1125), // 5K Studio Display
            (1964, 3024, "0.661375", 1299, 2000), // portrait
            (1920, 1080, "1.000000", 1920, 1080), // non-Retina: unchanged
            (2000, 1000, "1.000000", 2000, 1000),
        ]
        for c in cases {
            let scale = Scaling.scale(nativeWidth: c.w, nativeHeight: c.h)
            let size = Scaling.imageSize(nativeWidth: c.w, nativeHeight: c.h, scale: scale)
            XCTAssertEqual(Scaling.formatted(scale), c.scale, "\(c)")
            XCTAssertEqual(size.width, c.iw, "\(c)")
            XCTAssertEqual(size.height, c.ih, "\(c)")
            XCTAssertLessThanOrEqual(max(size.width, size.height), 2000, "\(c)")
            // The stated decimal is exactly the scale used to resize.
            XCTAssertEqual(Double(Scaling.formatted(scale)), scale, "\(c)")
        }
    }

    func testEveryImagePixelMapsInsideItsNativeFootprint() {
        for native in [3024, 3456, 5120, 1920] {
            let scale = Scaling.scale(nativeWidth: native, nativeHeight: 100)
            let imageWidth = Scaling.imageSize(nativeWidth: native, nativeHeight: 100, scale: scale).width
            for x in 0..<imageWidth {
                let mapped = Coordinates.nativeCoordinate(x, scale: scale)
                XCTAssertGreaterThanOrEqual(Double(mapped), (Double(x) / scale).rounded(.down), "\(native) \(x)")
                XCTAssertLessThan(Double(mapped), Double(x + 1) / scale, "\(native) \(x)")
                XCTAssertLessThan(mapped, native, "\(native) \(x)")
            }
        }
        XCTAssertEqual(Coordinates.nativeCoordinate(1234, scale: 1), 1234)
    }

    // MARK: - End to end: image-space click lands on the native target

    func testClickReadOffClaudeScreenshotLandsOnNativeTarget() async throws {
        // Native Retina capture (3024x1964 px = 1512x982 pt at 2x) with small
        // red targets, including near the edges.
        let targets = [
            CGRect(x: 2400, y: 1500, width: 12, height: 12),
            CGRect(x: 0, y: 0, width: 8, height: 8),
            CGRect(x: 3014, y: 1954, width: 10, height: 10),
            CGRect(x: 1511, y: 981, width: 4, height: 4),
        ]
        for target in targets {
            let raw: [[String: Any]] = [
                ["type": "image", "data": try pngBase64(width: 3024, height: 1964, red: target), "mimeType": "image/png"],
                ["type": "text", "text": "Captured display 0 at 3024x1964 pixels. Click/scroll coordinates are in this same pixel space."],
            ]
            let claude = relay_vision_mcp.MCPServer()
            _ = try await claude.dispatch(method: "initialize", params: ["clientInfo": ["name": "claude-code"]])
            let content = try claude.toolContent(name: "screenshot", arguments: [:], raw: raw)

            let image = try decode(try XCTUnwrap(content.first?["data"] as? String))
            XCTAssertEqual(image.width, 2000)
            XCTAssertEqual(image.height, 1299)
            let text = try XCTUnwrap(content.last?["text"] as? String)
            XCTAssertTrue(text.contains("3024x1964 native pixels"), text)
            XCTAssertTrue(text.contains("returned at 2000x1299 (screenshot_scale 0.661375)"), text)

            // What the model does: read the target off the image, pass the scale.
            let (ix, iy) = try reddestPixel(in: image)
            let mapped = try Coordinates.nativeArguments(
                tool: "click",
                ["x": ix, "y": iy, "screenshot_scale": 0.661375, "button": "left"]
            )
            let nx = try XCTUnwrap(mapped["x"] as? Int)
            let ny = try XCTUnwrap(mapped["y"] as? Int)
            XCTAssertNil(mapped["screenshot_scale"])
            XCTAssertEqual(mapped["button"] as? String, "left")
            // Within one native pixel of the target (downsampling blurs edges).
            XCTAssertTrue(target.insetBy(dx: -1, dy: -1).contains(CGPoint(x: nx, y: ny)), "\(target) -> (\(nx), \(ny))")
            // The app's unchanged pixel-to-point step (divide by the 2x
            // backing scale) then lands inside the target's point rect.
            let point = CGPoint(x: CGFloat(nx) / 2, y: CGFloat(ny) / 2)
            let pointRect = CGRect(x: target.minX / 2, y: target.minY / 2, width: target.width / 2, height: target.height / 2)
            XCTAssertTrue(pointRect.insetBy(dx: -0.5, dy: -0.5).contains(point), "\(pointRect) -> \(point)")
        }
    }

    func testSmallDisplayImageIsReturnedUnchangedWithScaleOne() throws {
        let data = try pngBase64(width: 1920, height: 1080, red: CGRect(x: 10, y: 10, width: 2, height: 2))
        let content = try Scaling.downscale(
            content: [["type": "image", "data": data, "mimeType": "image/png"]],
            displayIndex: 1
        )
        XCTAssertEqual(content.first?["data"] as? String, data)
        XCTAssertEqual(content.last?["text"] as? String, """
            Captured display 1 at 1920x1080 native pixels, returned at 1920x1080 (screenshot_scale 1.000000). \
            Read click/scroll x/y off this image and pass screenshot_scale 1.000000; Relay Actions maps them back to native pixels.
            """)
    }

    // MARK: - Codex stays byte-identical

    func testCodexScreenshotContentPassesThroughUnchanged() async throws {
        let raw: [[String: Any]] = [
            ["type": "image", "data": try pngBase64(width: 3024, height: 1964, red: .zero), "mimeType": "image/png"],
            ["type": "text", "text": "Captured display 0 at 3024x1964 pixels. Click/scroll coordinates are in this same pixel space."],
        ]
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = relay_vision_mcp.MCPServer()
            _ = try await server.dispatch(method: "initialize", params: ["clientInfo": ["name": client]])
            let content = try server.toolContent(name: "screenshot", arguments: [:], raw: raw)
            XCTAssertEqual(try mcpCanonicalJSONSHA256(content), try mcpCanonicalJSONSHA256(raw), client)
        }
    }

    func testCodexClickAndScrollArgumentsPassThroughUnchanged() async throws {
        let click: [String: Any] = ["x": 3000, "y": 1900, "button": "right", "double": true, "modifiers": ["cmd"]]
        let scroll: [String: Any] = ["x": 3000, "y": 1900, "dy": -3]
        for client in ["codex-mcp-client", "rr-326-probe"] {
            let server = relay_actions_mcp.MCPServer()
            _ = try await server.dispatch(method: "initialize", params: ["clientInfo": ["name": client]])
            for (name, arguments) in [("click", click), ("scroll", scroll)] {
                let forwarded = try server.toolArguments(name: name, arguments: arguments)
                XCTAssertEqual(try mcpCanonicalJSONSHA256(forwarded), try mcpCanonicalJSONSHA256(arguments), "\(client) \(name)")
            }
        }
    }

    // MARK: - Claude click/scroll contract

    func testClaudeClickAndScrollRequireScreenshotScale() async throws {
        let server = relay_actions_mcp.MCPServer()
        _ = try await server.dispatch(method: "initialize", params: ["clientInfo": ["name": "claude-code"]])

        let list = try await server.dispatch(method: "tools/list", params: [:]) as? [String: Any]
        let tools = try XCTUnwrap(list?["tools"] as? [[String: Any]])
        for name in ["click", "scroll"] {
            let schema = try XCTUnwrap(tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
            XCTAssertEqual((schema["required"] as? [String])?.last, "screenshot_scale", name)
            XCTAssertNotNil((schema["properties"] as? [String: Any])?["screenshot_scale"], name)
        }

        let scroll = try server.toolArguments(name: "scroll", arguments: ["x": 1000, "y": 650, "dy": 2, "screenshot_scale": 0.661375])
        XCTAssertEqual(scroll["x"] as? Int, 1512)
        XCTAssertEqual(scroll["y"] as? Int, 983)
        XCTAssertEqual(scroll["dy"] as? Int, 2)
        XCTAssertNil(scroll["screenshot_scale"])
        XCTAssertEqual(try server.toolArguments(name: "type", arguments: ["text": "hi"])["text"] as? String, "hi")

        // Missing or out-of-range scale is rejected before the app is contacted.
        for bad in [nil, 0, 1.5, -0.5] as [Double?] {
            var arguments: [String: Any] = ["x": 10, "y": 10]
            arguments["screenshot_scale"] = bad
            let result = try await server.dispatch(method: "tools/call", params: ["name": "click", "arguments": arguments]) as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, true, "\(String(describing: bad))")
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
            XCTAssertEqual(text?.contains("requires screenshot_scale"), true)
        }
    }

    // MARK: - Helpers

    /// White image with one red rect, in top-left-origin pixel coordinates.
    private func pngBase64(width: Int, height: Int, red: CGRect) throws -> String {
        let context = try XCTUnwrap(rgbaContext(width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: red.minX, y: CGFloat(height) - red.maxY, width: red.width, height: red.height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    private func decode(_ base64: String) throws -> CGImage {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Top-left-origin pixel with the strongest red-over-green signal.
    private func reddestPixel(in image: CGImage) throws -> (Int, Int) {
        let context = try XCTUnwrap(rgbaContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var best = (x: 0, y: 0, score: -1)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * context.bytesPerRow + x * 4
                let score = Int(pixels[offset]) - Int(pixels[offset + 1])
                if score > best.score { best = (x, y, score) }
            }
        }
        return (best.x, best.y) // bitmap memory rows are top-down
    }

    private func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
