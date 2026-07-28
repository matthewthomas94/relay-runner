import AppKit
import Darwin
import MetalKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import relay_runner

/// Opt-in measurement harness for RR-237. The normal suite skips these tests;
/// run with `RR237_BENCHMARK=board` or `RR237_BENCHMARK=terminal`.
@MainActor
final class RR237ResponsivenessBenchmarkTests: XCTestCase {
    func testProgramBoardEventAndSortLatency() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RR237_BENCHMARK"] == "board")

        let repoPath = "/benchmark/relay-runner"
        let items = (1...227).map { index in
            ProgramStatusItem(
                project: ProgramStatusProject(name: "relay-runner", path: repoPath),
                ticketID: "RR-BENCH-\(index)",
                title: "Mounted ticket \(index)",
                status: Ticket.Status.done.rawValue,
                priority: Ticket.Priority.medium.rawValue,
                ticketModifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let unorderedItems = (0..<items.count).map {
            items[($0 * 67) % items.count]
        }
        var orderingSamples: [Double] = []
        for offset in 0..<20 {
            let split = offset % unorderedItems.count
            let rotated = Array(unorderedItems[split...] + unorderedItems[..<split])
            let start = DispatchTime.now().uptimeNanoseconds
            let ordered = dashboard(done: rotated).ticketItems(in: .done, selectedProjectPath: nil)
            orderingSamples.append(milliseconds(since: start))
            XCTAssertEqual(ordered.count, items.count)
            XCTAssertEqual(ordered.first?.ticketID, "RR-BENCH-227")
        }

        let model = ProgramBoardViewModel()
        let backlog = ProgramStatusItem(
            project: ProgramStatusProject(name: "relay-runner", path: repoPath),
            ticketID: "RR-DRAG",
            title: "Mounted drag benchmark",
            status: Ticket.Status.backlog.rawValue,
            priority: Ticket.Priority.medium.rawValue,
            ticketModifiedAt: Date()
        )
        model.snapshot = dashboard(backlog: [backlog], done: unorderedItems)

        let host = NSHostingView(rootView:
            HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                benchmarkColumn(model: model, lane: .backlog)
                benchmarkColumn(model: model, lane: .ready)
                benchmarkColumn(model: model, lane: .inProgress)
            }
            .frame(width: 850, height: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
            .coordinateSpace(name: "programBoard")
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 850, height: BoardSurfaceLayout.columnHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        drainMainQueue()

        let columnWidth = (CGFloat(850) - BoardSurfaceLayout.columnSpacing * 2) / 3
        model.boardFrameInWindow = window.contentView!.bounds
        model.columnFrames = [
            .backlog: CGRect(x: 0, y: 0, width: columnWidth, height: BoardSurfaceLayout.columnHeight),
            .ready: CGRect(
                x: columnWidth + BoardSurfaceLayout.columnSpacing,
                y: 0,
                width: columnWidth,
                height: BoardSurfaceLayout.columnHeight
            ),
            .inProgress: CGRect(
                x: (columnWidth + BoardSurfaceLayout.columnSpacing) * 2,
                y: 0,
                width: columnWidth,
                height: BoardSurfaceLayout.columnHeight
            ),
        ]

        let eventView = try XCTUnwrap(findDragEventView(in: host))
        var hoverSamples: [Double] = []
        var hoverStart: UInt64 = 0
        eventView.onHoverChange = { hovering in
            if hovering {
                hoverSamples.append(self.milliseconds(since: hoverStart))
            }
        }
        let hoverEvent = try XCTUnwrap(mouseEvent(.mouseMoved, at: .zero, window: window))
        for _ in 0..<100 {
            hoverStart = DispatchTime.now().uptimeNanoseconds
            eventView.mouseEntered(with: hoverEvent)
            eventView.mouseExited(with: hoverEvent)
        }

        let start = CGPoint(x: 80, y: ProgramBoardLayout.workCardTopOffset + 30)
        let ready = CGPoint(
            x: model.columnFrames[.ready]!.midX,
            y: ProgramBoardLayout.workCardTopOffset + 30
        )
        let startInWindow = windowLocation(start, windowHeight: BoardSurfaceLayout.columnHeight)
        let readyInWindow = windowLocation(ready, windowHeight: BoardSurfaceLayout.columnHeight)
        let dragStart = DispatchTime.now().uptimeNanoseconds
        eventView.mouseDown(with: try XCTUnwrap(mouseEvent(.leftMouseDown, at: startInWindow, window: window)))
        eventView.mouseDragged(with: try XCTUnwrap(mouseEvent(.leftMouseDragged, at: readyInWindow, window: window)))
        let dragMilliseconds = milliseconds(since: dragStart)
        XCTAssertEqual(model.dragTarget, ProgramBoardDropTarget(lane: .ready, isValid: true))
        eventView.mouseUp(with: try XCTUnwrap(mouseEvent(.leftMouseUp, at: readyInWindow, window: window)))

        var queuedHoverSamples: [Double] = []
        for index in 0..<20 {
            let queuedHover = expectation(description: "hover after snapshot replacement \(index)")
            let queuedHoverStart = DispatchTime.now().uptimeNanoseconds
            hoverStart = queuedHoverStart
            DispatchQueue.main.async {
                eventView.mouseEntered(with: hoverEvent)
                queuedHoverSamples.append(self.milliseconds(since: queuedHoverStart))
                queuedHover.fulfill()
            }
            model.snapshot = dashboard(backlog: [backlog], done: Array(unorderedItems.reversed()))
            wait(for: [queuedHover], timeout: 2)
            eventView.mouseExited(with: hoverEvent)
        }

        var queuedDragSamples: [Double] = []
        for index in 0..<20 {
            let queuedDrag = expectation(description: "eligible drag after snapshot replacement \(index)")
            let queuedDragStart = DispatchTime.now().uptimeNanoseconds
            let queuedMouseDown = try XCTUnwrap(mouseEvent(.leftMouseDown, at: startInWindow, window: window))
            let queuedMouseDragged = try XCTUnwrap(mouseEvent(.leftMouseDragged, at: readyInWindow, window: window))
            let queuedMouseUp = try XCTUnwrap(mouseEvent(.leftMouseUp, at: readyInWindow, window: window))
            DispatchQueue.main.async {
                eventView.mouseDown(with: queuedMouseDown)
                eventView.mouseDragged(with: queuedMouseDragged)
                queuedDragSamples.append(self.milliseconds(since: queuedDragStart))
                eventView.mouseUp(with: queuedMouseUp)
                queuedDrag.fulfill()
            }
            model.snapshot = dashboard(backlog: [backlog], done: unorderedItems)
            wait(for: [queuedDrag], timeout: 2)
            XCTAssertEqual(model.dragTarget, nil)
        }

        let manualInProgress = model.dropRequest(
            for: backlog,
            sourceLane: .backlog,
            targetLane: .inProgress
        ) != nil
        XCTAssertFalse(manualInProgress)
        XCTAssertLessThan(percentileValue(orderingSamples, 0.50), 8)
        XCTAssertLessThan(percentileValue(orderingSamples, 0.95), 16.7)
        XCTAssertLessThan(percentileValue(queuedHoverSamples, 0.95), 16.7)
        XCTAssertLessThan(percentileValue(queuedDragSamples, 0.95), 25)
        print(
            "RR237_BOARD tickets=\(items.count) "
                + "sort_p50_ms=\(percentile(orderingSamples, 0.50)) "
                + "sort_p95_ms=\(percentile(orderingSamples, 0.95)) "
                + "hover_p50_ms=\(percentile(hoverSamples, 0.50)) "
                + "hover_p95_ms=\(percentile(hoverSamples, 0.95)) "
                + "drag_to_ready_ms=\(dragMilliseconds) "
                + "queued_hover_p95_ms=\(percentile(queuedHoverSamples, 0.95)) "
                + "queued_drag_p95_ms=\(percentile(queuedDragSamples, 0.95)) "
                + "manual_in_progress_rejected=\(!manualInProgress)"
        )
    }

    func testSwiftTermPTYAndRendererLatency() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RR237_BENCHMARK"] == "terminal")
        let renderer = ProcessInfo.processInfo.environment["RR237_RENDERER"] ?? "core-graphics"
        let probe = RR237TerminalProbe(renderer: renderer)
        try probe.start()
        defer { probe.stop() }

        for index in 0..<10 {
            probe.feedAndRender(frame(index))
        }
        var interactiveRenderSamples: [Double] = []
        for index in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            probe.feedAndRender(frame(index + 10))
            interactiveRenderSamples.append(milliseconds(since: start))
        }

        let highOutput = Array(
            (0..<6_000)
                .map { "\u{1b}[38;5;\($0 % 256)mRR237 output row \($0) \(String(repeating: "x", count: 72))\u{1b}[0m\r\n" }
                .joined()
                .utf8
        )
        let highOutputStart = DispatchTime.now().uptimeNanoseconds
        for offset in stride(from: 0, to: highOutput.count, by: 64 * 1024) {
            let end = min(offset + 64 * 1024, highOutput.count)
            probe.feedAndRender(Array(highOutput[offset..<end]))
        }
        let highOutputMilliseconds = milliseconds(since: highOutputStart)

        var inputToSend: [Double] = []
        var sendToPTYOutput: [Double] = []
        var outputToRender: [Double] = []
        var visibleInput: [Double] = []
        for _ in 0..<30 {
            let completed = expectation(description: "PTY echo rendered")
            probe.beginInputTrial {
                inputToSend.append($0.inputToSend)
                sendToPTYOutput.append($0.sendToOutput)
                outputToRender.append($0.outputToRender)
                visibleInput.append($0.inputToRender)
                completed.fulfill()
            }
            probe.terminalView.insertText(
                "z",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            wait(for: [completed], timeout: 2)
        }

        print(
            "RR237_TERMINAL renderer=\(renderer) "
                + "input_to_send_p50_ms=\(percentile(inputToSend, 0.50)) "
                + "input_to_send_p95_ms=\(percentile(inputToSend, 0.95)) "
                + "send_to_pty_output_p50_ms=\(percentile(sendToPTYOutput, 0.50)) "
                + "send_to_pty_output_p95_ms=\(percentile(sendToPTYOutput, 0.95)) "
                + "output_to_render_p50_ms=\(percentile(outputToRender, 0.50)) "
                + "output_to_render_p95_ms=\(percentile(outputToRender, 0.95)) "
                + "visible_input_p50_ms=\(percentile(visibleInput, 0.50)) "
                + "visible_input_p95_ms=\(percentile(visibleInput, 0.95)) "
                + "frame_p50_ms=\(percentile(interactiveRenderSamples, 0.50)) "
                + "frame_p95_ms=\(percentile(interactiveRenderSamples, 0.95)) "
                + "high_output_bytes=\(highOutput.count) "
                + "high_output_ms=\(highOutputMilliseconds) "
                + "peak_rss_mib=\(peakRSSMiB())"
        )
    }

    private func benchmarkColumn(
        model: ProgramBoardViewModel,
        lane: ProgramBoardLane
    ) -> some View {
        ProgramWorkColumnPanel(
            model: model,
            lane: lane,
            showsProjectContext: true,
            theme: nil,
            canCreate: true,
            onCreate: {},
            onEdit: { _ in },
            onDrop: { _, _, _ in }
        )
    }

    private func dashboard(
        backlog: [ProgramStatusItem] = [],
        done: [ProgramStatusItem] = []
    ) -> ProgramDashboardSnapshot {
        func response(_ query: String, _ items: [ProgramStatusItem]) -> ProgramStatusResponse {
            ProgramStatusResponse(
                query: query,
                provider: nil,
                message: "RR-237 benchmark",
                items: items,
                counts: ProgramStatusCounts(projects: 1, items: items.count)
            )
        }
        return ProgramDashboardSnapshot(
            summary: response("summary", []),
            backlogWork: response("backlog_lane", backlog),
            readyWork: response("ready_lane", []),
            inProgressWork: response("in_progress_lane", []),
            doneWork: response("done_lane", done),
            awaitingMerge: response("awaiting_merge", [])
        )
    }

    private func frame(_ index: Int) -> [UInt8] {
        Array(
            ("\u{1b}[H" + (0..<42).map {
                "\u{1b}[38;5;\(($0 + index) % 256)m"
                    + "RR237 frame \(index) row \($0) "
                    + String(repeating: Character(UnicodeScalar(65 + (($0 + index) % 26))!), count: 96)
                    + "\u{1b}[0m\r\n"
            }.joined()).utf8
        )
    }

    private func findDragEventView(in view: NSView) -> ProgramWorkCardDragEventView? {
        if let eventView = view as? ProgramWorkCardDragEventView { return eventView }
        return view.subviews.lazy.compactMap(findDragEventView).first
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )
    }

    private func windowLocation(_ point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: windowHeight - point.y)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func percentile(_ samples: [Double], _ percentile: Double) -> String {
        String(format: "%.3f", percentileValue(samples, percentile))
    }

    private func percentileValue(_ samples: [Double], _ percentile: Double) -> Double {
        guard !samples.isEmpty else { return .infinity }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)
        return sorted[max(0, index)]
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func peakRSSMiB() -> String {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return String(format: "%.1f", Double(usage.ru_maxrss) / 1_048_576)
    }
}

private final class RR237TerminalProbe: NSObject, TerminalViewDelegate, LocalProcessDelegate {
    struct InputTiming {
        let inputToSend: Double
        let sendToOutput: Double
        let outputToRender: Double
        let inputToRender: Double
    }

    let terminalView = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 700))
    private let window: NSWindow
    private lazy var process = LocalProcess(delegate: self)
    private let renderer: String
    private var inputStartedAt: UInt64?
    private var sendReachedAt: UInt64?
    private var completion: ((InputTiming) -> Void)?

    init(renderer: String) {
        self.renderer = renderer
        window = NSWindow(
            contentRect: terminalView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        terminalView.terminalDelegate = self
        window.contentView = terminalView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
    }

    func start() throws {
        if renderer == "metal" {
            try terminalView.setUseMetal(true)
            guard terminalView.isUsingMetalRenderer else {
                throw XCTSkip("Metal renderer did not activate")
            }
        }
        process.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: ["TERM=xterm-256color", "COLORTERM=truecolor"],
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        guard process.running else {
            throw EmbeddedTerminalProcessError.couldNotStart
        }
    }

    func stop() {
        completion = nil
        process.terminate()
        window.orderOut(nil)
    }

    func beginInputTrial(_ completion: @escaping (InputTiming) -> Void) {
        inputStartedAt = DispatchTime.now().uptimeNanoseconds
        sendReachedAt = nil
        self.completion = completion
    }

    func feedAndRender(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
        renderNow()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if inputStartedAt != nil, sendReachedAt == nil {
            sendReachedAt = DispatchTime.now().uptimeNanoseconds
        }
        process.send(data: data)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let outputAt = DispatchTime.now().uptimeNanoseconds
        terminalView.feed(byteArray: slice)
        renderNow()
        let renderedAt = DispatchTime.now().uptimeNanoseconds
        guard let inputAt = inputStartedAt,
              let sendAt = sendReachedAt,
              let completion else {
            return
        }
        inputStartedAt = nil
        sendReachedAt = nil
        self.completion = nil
        completion(InputTiming(
            inputToSend: milliseconds(inputAt, sendAt),
            sendToOutput: milliseconds(sendAt, outputAt),
            outputToRender: milliseconds(outputAt, renderedAt),
            inputToRender: milliseconds(inputAt, renderedAt)
        ))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}

    func getWindowSize() -> winsize {
        winsize(
            ws_row: UInt16(max(1, terminalView.getTerminal().rows)),
            ws_col: UInt16(max(1, terminalView.getTerminal().cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
    }

    private func renderNow() {
        terminalView.layoutSubtreeIfNeeded()
        if renderer == "metal", let metalView = findMetalView(in: terminalView) {
            metalView.draw()
        } else {
            terminalView.display()
        }
    }

    private func findMetalView(in view: NSView) -> MTKView? {
        if let metalView = view as? MTKView { return metalView }
        return view.subviews.lazy.compactMap(findMetalView).first
    }

    private func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}
