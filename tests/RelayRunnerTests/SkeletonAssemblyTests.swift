import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

final class SkeletonAssemblyTests: XCTestCase {
    func testSketchAndContentShareOneEdgeInEitherCoordinateSystem() {
        let bounds = CGRect(x: 20, y: 30, width: 900, height: 600)
        for flipped in [false, true] {
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let content = SkeletonAssembly.clipRect(in: bounds, progress: progress, sketch: false, flipped: flipped)
                let sketch = SkeletonAssembly.clipRect(in: bounds, progress: progress, sketch: true, flipped: flipped)
                XCTAssertEqual(content.height + sketch.height, bounds.height)
                XCTAssertEqual(content.union(sketch), bounds)
                XCTAssertEqual(flipped ? content.maxY : content.minY, flipped ? sketch.minY : sketch.maxY)
                XCTAssertEqual(content.height, bounds.height * progress)
            }
        }
    }

    func testWorkspaceScanAccountsForTheNotchStripAndFlippedLoader() {
        // The hosted Workspace uses bottom-left coordinates; its loader starts
        // below the 34pt notch strip and uses top-left coordinates.
        let contentBounds = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let loaderBounds = CGRect(x: 0, y: 0, width: 1_200, height: 726)
        let scan = CGRect(x: 0, y: 140, width: 1_200, height: 726)
        for progress: CGFloat in [0, 0.2, 0.5, 1] {
            let content = SkeletonAssembly.clipRect(in: contentBounds, progress: progress,
                                                     sketch: false, flipped: false, scanBounds: scan)
            let sketch = SkeletonAssembly.clipRect(in: loaderBounds, progress: progress, sketch: true)
            XCTAssertEqual(contentBounds.height - content.minY, 34 + sketch.minY, accuracy: 0.001)
        }
    }

    func testChromeStaysWholePastTheEdgeThenFadesLast() {
        XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: 0), 1)
        XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: 0.6), 1)
        XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: 0.8), 0.5, accuracy: 0.001)
        XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: 1), 0)
        XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: 2), 0)
        for stop in SkeletonAssembly.chromeOpacityStops {
            XCTAssertEqual(SkeletonAssembly.chromeOpacity(progress: CGFloat(stop.progress)), stop.opacity,
                           "The native keyframes and the SwiftUI curve agree")
        }
    }

    @MainActor
    func testCancelingAssemblyDoesNotRunItsStaleCompletionOrRemoveAnotherMask() throws {
        try XCTSkipIf(RelayLayerMotion.reduceMotion, "The system disables scanning")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.wantsLayer = true
        var completions = 0
        SkeletonAssembly.animateMask(on: view, sketch: true) { completions += 1 }
        XCTAssertEqual(view.layer?.mask?.name, SkeletonAssembly.maskName)
        SkeletonAssembly.cancel(on: view)
        let otherMask = CALayer()
        otherMask.name = "surfaceShape"
        view.layer?.mask = otherMask
        SkeletonAssembly.cancel(on: view)
        RunLoop.main.run(until: Date().addingTimeInterval(SkeletonAssembly.duration + 0.1))
        XCTAssertTrue(view.layer?.mask === otherMask)
        XCTAssertEqual(completions, 0, "A canceled exit cannot remove a reused loader")
    }

    @MainActor
    func testReduceMotionSkipsTheScanAndCompletesImmediately() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.wantsLayer = true
        var completions = 0
        SkeletonAssembly.animateMask(on: view, sketch: false, reduceMotion: true) { completions += 1 }
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(completions, 1)
        XCTAssertLessThan(SkeletonAssembly.duration(reduceMotion: true), SkeletonAssembly.duration)
    }

    /// Renders the actual Workspace with local fixture data, without launching
    /// Relay or connecting to the user's daemon, projects, or terminal sessions.
    @MainActor
    func testWorkspaceAssemblyRendering() throws {
        guard let directory = ProcessInfo.processInfo.environment["RELAY_ASSEMBLY_RENDER_DIR"] else {
            throw XCTSkip("Set RELAY_ASSEMBLY_RENDER_DIR to export the native handoff")
        }
        try XCTSkipIf(RelayLayerMotion.reduceMotion, "The system disables scanning")
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let size = CGSize(width: 1_400, height: 820)
        let model = ProgramBoardViewModel()
        model.snapshot = try previewSnapshot()
        model.projectPaths = ["/preview/relay-runner", "/preview/general-tasks", "/preview/hidpress-web"]
        let workspace = WorkspaceViewModel()
        let root = ProgramBoardOverlayView(
            model: model, workspace: workspace, settingsContent: nil,
            terminalContent: { _ in nil }, onDismiss: {}, onWorkspaceTabChange: { _ in }, onRefresh: {},
            onStartSession: {}, onEndSession: {}, onCreateStart: { _ in }, onCreateCommit: { _ in },
            onCreateCancel: {}, onEditStart: { _ in }, onEditCommit: { _ in }, onEditCancel: {},
            onDelete: { _ in }, onSpikeFollowupStart: { _ in }, onSpikeFollowupReview: { _, _, _, _ in },
            onSpikeFollowupClose: {}, onDrop: { _, _, _ in }
        ).environment(\.colorScheme, .dark)
        let hosted = BoardOverlayHostingView(rootView: root)
        let frame = CGRect(origin: .zero, size: size)
        let container = BoardRevealContainerView(frame: frame, contentView: hosted,
                                                 displayGeometry: .init(screenFrame: frame), startsLoading: true)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        container.layoutSubtreeIfNeeded()
        let expanded = expectation(description: "Workspace expanded")
        container.animateReveal { expanded.fulfill() }
        wait(for: [expanded], timeout: 5)
        let contentContainer = try XCTUnwrap(hosted.superview)
        func capture(_ name: String, ready: () -> Void) throws {
            let destination = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // CPU layer rendering is slower than the compositor. Sample the
            // native animation on a slowed layer clock, then replay at 24fps.
            let rate = name == "workspace" ? 0.125 : 1.0
            let layer = try XCTUnwrap(container.layer)
            if rate != 1 {
                layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.beginTime = CACurrentMediaTime()
                layer.speed = Float(rate)
            }
            defer {
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
            }
            let started = Date()
            var frames: [NSBitmapImageRep] = []
            for index in 0..<54 {
                RunLoop.main.run(until: started.addingTimeInterval(Double(index) / (24 * rate)))
                if index == 18 { ready() }
                frames.append(try render(try XCTUnwrap(container.layer?.presentation()), size: size))
            }
            // Encode after capturing so PNG compression cannot stall the reveal.
            for (index, bitmap) in frames.enumerated() {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent(String(format: "%03d.png", index)))
            }
        }
        try capture("workspace") { container.setLoading(false) }
        XCTAssertTrue(hosted.superview === contentContainer, "Assembly preserves the hosted UI")
        XCTAssertEqual(contentContainer.alphaValue, 1)
        XCTAssertNil(contentContainer.layer?.mask)

        workspace.select(.notes)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        try capture("notes") { model.notesLoaded = true }
    }

    private func previewSnapshot() throws -> ProgramDashboardSnapshot {
        func item(_ fields: [String: Any]) throws -> ProgramStatusItem {
            try JSONDecoder().decode(ProgramStatusItem.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let project = ["name": "relay-runner", "path": "/preview/relay-runner"]
        let projects = try ["relay-runner", "general-tasks", "hidpress-web"].map { name in
            try item(["project": ["name": name, "path": "/preview/\(name)"],
                      "backlog_tickets": name == "relay-runner" ? 2 : 0,
                      "ready_tickets": 0, "in_progress_tickets": name == "relay-runner" ? 1 : 0,
                      "done_tickets": name == "relay-runner" ? 1 : 0])
        }
        func ticket(_ id: String, _ title: String, _ status: String) throws -> ProgramStatusItem {
            try item(["project": project, "ticket_id": id, "title": title, "status": status,
                      "priority": "medium", "depends_on": [], "blocked_by": []])
        }
        func response(_ query: String, _ items: [ProgramStatusItem] = []) -> ProgramStatusResponse {
            ProgramStatusResponse(query: query, provider: nil, message: "", items: items,
                                  counts: ProgramStatusCounts(projects: 3, items: items.count))
        }
        return try ProgramDashboardSnapshot(
            summary: response("summary", projects),
            backlogWork: response("backlog_lane", [ticket("RR-1", "Polish the session wheel", "backlog"),
                                                   ticket("RR-2", "Refine Workspace transitions", "backlog")]),
            readyWork: response("ready_lane"),
            inProgressWork: response("in_progress_lane", [ticket("RR-3", "Assemble UI from the dot sketch", "in_progress")]),
            doneWork: response("done_lane", [ticket("RR-4", "Add the dotted skeleton loader", "done")]),
            awaitingMerge: response("awaiting_merge")
        )
    }

    private func render(_ layer: CALayer, size: CGSize) throws -> NSBitmapImageRep {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }
}
