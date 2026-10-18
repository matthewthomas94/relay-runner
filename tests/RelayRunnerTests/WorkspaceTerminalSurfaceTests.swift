import SwiftUI
import XCTest
@testable import relay_runner

final class WorkspaceTerminalSurfaceTests: XCTestCase {
    func testSelectedTabJoinsThePanelAndOtherTabsHaveAnOpenGap() {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 300)
        for x: CGFloat in [24, 180, 340] {
            let outline = WorkspaceTerminalOutline(
                tabFrame: CGRect(x: x, y: 0, width: 140, height: 40), contentTop: 48
            ).path(in: rect)
            // No seam or gap between the selected cap, shoulder, and panel.
            for y: CGFloat in [20, 39, 44, 48, 60, 150] {
                XCTAssertTrue(outline.contains(CGPoint(x: x + 70, y: y)))
            }
            XCTAssertFalse(outline.contains(CGPoint(x: x + 155, y: 44)))
            XCTAssertTrue(outline.contains(CGPoint(x: 600, y: 150)))
        }
    }

    func testContourCanRetargetToAnIntermediatePositionWithoutChangingThePanel() {
        var shape = WorkspaceTerminalOutline(
            tabFrame: CGRect(x: 24, y: 0, width: 140, height: 40), contentTop: 48
        )
        shape.animatableData = AnimatablePair(100, 170)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 640, height: 300))
        XCTAssertTrue(path.contains(CGPoint(x: 180, y: 20)))
        XCTAssertFalse(path.contains(CGPoint(x: 50, y: 20)))
        XCTAssertTrue(path.contains(CGPoint(x: 50, y: 80)))
    }

    func testShouldersStayConcentricWithBothAdjacentTabCorners() {
        // Core Graphics preserves curve precision for subpixel gap checks.
        let outline = WorkspaceTerminalOutline(
            tabFrame: CGRect(x: 200, y: 0, width: 140, height: 40), contentTop: 48
        ).path(in: CGRect(x: 0, y: 0, width: 640, height: 300)).cgPath

        // Adjacent tabs end at x=192 and start at x=348. Their bottom
        // corners have centers at (180, 28) and (360, 28). Both outlines
        // must remain circular about those centers to keep an 8pt clear gap.
        let corners: [(CGFloat, CGFloat)] = [(180, 1), (360, -1)]
        for (centerX, direction) in corners {
            for degrees in stride(from: 0.0, through: 90.0, by: 15) {
                let angle = CGFloat(degrees) * .pi / 180
                func point(_ radius: CGFloat) -> CGPoint {
                    CGPoint(x: centerX + direction * cos(angle) * radius,
                            y: 28 + sin(angle) * radius)
                }
                // The outer border center is 20.5pt from the shared center;
                // the detached tab's inset border is 11.5pt from it.
                XCTAssertFalse(outline.contains(point(20.3)), "Gap pinched at \(degrees) degrees")
                XCTAssertTrue(outline.contains(point(20.7)), "Gap widened at \(degrees) degrees")
            }
        }
    }

    @MainActor
    func testTerminalSurfaceRendering() throws {
        let tabs = [("vial", "vial-qmk"), ("relay", "relay-runner"), ("hidpress", "hidpress")]
        for (selected, name) in tabs {
            let view = WorkspaceTerminalSurface(
                tabs: tabs,
                selectedID: selected, badges: [:], select: { _ in }, readOut: { _ in }, close: { _ in }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("~/dev/\(name)")
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                    Text("› Ready for your next message")
                    Spacer()
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 640, height: 240)
            .padding(24)
            .background(.black)
            .foregroundStyle(ProgramBoardStyle.primaryText)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("terminal-\(selected).png"))
            }
        }
    }
}
