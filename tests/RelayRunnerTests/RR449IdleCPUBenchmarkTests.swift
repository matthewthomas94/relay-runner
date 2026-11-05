import AppKit
import Darwin
import XCTest
@testable import relay_runner

/// Opt-in idle-CPU measurements for RR-449. The normal suite skips these;
/// run with `RR449_BENCHMARK=1`. Point `RR449_PROVIDER_TURNS` at a copy of
/// `/tmp/voice_provider_turns_v2.json` and `RR449_TICKETS` at a directory of
/// copied `.orchestrator/*.md` files to measure against copied live state.
/// Each test prints the cost per call and the main-thread or worker CPU per
/// minute at the cadence the idle app runs it.
@MainActor
final class RR449IdleCPUBenchmarkTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["RR449_BENCHMARK"] == "1")
    }

    /// The 1 s Workspace activity refresh and the 3 s context reconcile ask
    /// whether a foreground provider turn is active.
    func testProviderTurnActiveCheck() throws {
        let url = try providerTurnsFixture()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        _ = ProcessManager.providerTurnActive(providerTurnsURL: url, providerSessionID: "rr449")
        let calls = 400
        let cost = threadCPU {
            for _ in 0..<calls {
                _ = ProcessManager.providerTurnActive(providerTurnsURL: url, providerSessionID: "rr449")
            }
        }
        // 60 activity refreshes + 20 context reconciles a minute.
        report("provider turn check (\(size / 1024) KB store)", perCall: cost / Double(calls), callsPerMinute: 80)
    }

    /// The terminal delivery queue's 200 ms tick with nothing queued.
    func testIdleDeliveryTick() throws {
        let root = try temporaryDirectory()
        var paths = RelayVoiceCommandDelivery.Paths()
        for keyPath in [
            \RelayVoiceCommandDelivery.Paths.command, \.metadata, \.claimed, \.consumerAcknowledgement,
            \.commandState, \.providerTurns, \.manualSubmissions, \.deliveryEvents, \.actionJournal,
            \.voiceInput, \.heartbeat,
        ] {
            paths[keyPath: keyPath] = root.appendingPathComponent(UUID().uuidString).path
        }
        try Data(contentsOf: providerTurnsFixture()).write(to: URL(fileURLWithPath: paths.providerTurns))
        try #"{"relay_command_seq": 4, "relay_command_id": "done"}"#
            .write(toFile: paths.commandState, atomically: true, encoding: .utf8)
        let delivery = RelayVoiceCommandDelivery(paths: paths, send: { _ in }, isRunning: { true })
        _ = delivery.claimAndSendIfPossible()
        let ticks = 600
        let cost = threadCPU {
            for _ in 0..<ticks { _ = delivery.claimAndSendIfPossible() }
        }
        report("idle delivery tick", perCall: cost / Double(ticks), callsPerMinute: 300)
    }

    /// The STT poll's notch work: whether any work is active (20 Hz before
    /// RR-449; once per activity refresh after) and the label width the
    /// placement measures on each tick.
    func testNotchActivityTickPieces() throws {
        let tickets = try ticketsFixture()
        let calls = 2_000
        let activeWork = threadCPU {
            for _ in 0..<calls {
                _ = NotchActivityLabelPlanner.hasActiveWork(state: .idle, tickets: tickets)
            }
        }
        report("hasActiveWork over \(tickets.count) tickets", perCall: activeWork / Double(calls), callsPerMinute: 1_200)
        let waiting = threadCPU {
            for _ in 0..<calls {
                _ = NotchActivityLabelPlanner.hasWaitingDependency(in: tickets)
            }
        }
        report("hasWaitingDependency once per refresh", perCall: waiting / Double(calls), callsPerMinute: 60)
        let activeWorkWithoutTickets = threadCPU {
            for _ in 0..<calls {
                _ = NotchActivityLabelPlanner.hasActiveWork(state: .idle, tickets: [])
            }
        }
        report("hasActiveWork without tickets", perCall: activeWorkWithoutTickets / Double(calls), callsPerMinute: 1_200)
        let width = threadCPU {
            for _ in 0..<calls {
                _ = NotchStatusPlacementPlanner.activityLabelWidth(for: "RR-459 run 304: Editing files (Claude)")
            }
        }
        report("activity label width", perCall: width / Double(calls), callsPerMinute: 1_200)
    }

    /// The notch pill while work is active: its glyph loops at 60 Hz.
    /// Measures main-thread CPU (timer, draw and Core Animation commit) for
    /// the mounted pill over a few seconds of the real run loop.
    func testWorkingNotchGlyphAnimation() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )
        let label = "Worker running"
        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(
            for: geometry,
            activityLabelWidth: NotchStatusPlacementPlanner.activityLabelWidth(for: label)
        ))
        // Bottom-left of the real screen so the window draws, away from the live notch.
        let frame = CGRect(origin: screen.visibleFrame.origin, size: placement.visibleFrame.size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        let pillView = NotchStatusPillContentView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = pillView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        pillView.apply(
            status: .working,
            label: label,
            activityLabelWidth: placement.activityLabelWidth,
            leadingSpacerWidth: placement.leadingSpacerWidth,
            notchSpacerWidth: placement.notchSpacerWidth,
            glyphScreenX: nil
        )
        // Let the label's arrival and the status change settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let seconds = 4.0
        let cost = threadCPU {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        print(String(
            format: "RR449 BENCH working notch glyph animation: %.1f ms main-thread CPU per second (%.0f ms/min, %.2f%% CPU)",
            cost * 1_000 / seconds, cost * 60_000 / seconds, cost * 100 / seconds
        ))

        // The run loop and timer cost of any 60 Hz main-thread timer.
        let idleTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in }
        RunLoop.main.add(idleTimer, forMode: .common)
        pillView.removeFromSuperview()
        let timerCost = threadCPU {
            RunLoop.main.run(until: Date().addingTimeInterval(2))
        }
        idleTimer.invalidate()
        print(String(format: "RR449 BENCH empty 60 Hz timer: %.1f ms main-thread CPU per second", timerCost * 500))
    }

    // MARK: - Helpers

    private func providerTurnsFixture() throws -> URL {
        if let path = environment["RR449_PROVIDER_TURNS"] {
            return URL(fileURLWithPath: path)
        }
        // A store shaped like a long session's: a few hundred finished turns.
        let records = (0..<252).map { index -> [String: Any] in
            [
                "state": index % 3 == 0 ? "completed_final" : "completed_manual",
                "provider": index % 2 == 0 ? "claude" : "codex",
                "provider_session_id": UUID().uuidString,
                "relay_command_id": UUID().uuidString,
                "relay_command_seq": index,
                "turn_id": UUID().uuidString,
                "app_session_id": UUID().uuidString,
                "recovery_generation": UUID().uuidString,
                "foreground_gate_handle": UUID().uuidString,
                "actor_role": "foreground_pm",
                "updated_at": 1_793_000_000 + index,
                "started_at": 1_793_000_000 + index,
                "summary": String(repeating: "x", count: 300),
            ]
        }
        let url = try temporaryDirectory().appendingPathComponent("turns.json")
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 2, "records": records])
        try data.write(to: url)
        return url
    }

    private func ticketsFixture() throws -> [Ticket] {
        guard let path = environment["RR449_TICKETS"] else {
            return (1...150).map { index in
                Ticket(
                    id: "RR-\(index)",
                    title: "Ticket \(index)",
                    status: index % 5 == 0 ? .ready : .done,
                    priority: .medium,
                    dependsOn: index % 5 == 0 ? ["RR-\(index - 1)"] : [],
                    runId: nil,
                    canceled: false,
                    order: index,
                    description: nil,
                    body: String(repeating: "body ", count: 200)
                )
            }
        }
        let root = URL(fileURLWithPath: path)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var tickets: [Ticket] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md",
                  let contents = try? String(contentsOf: url, encoding: .utf8),
                  let ticket = try? TicketParser.parse(contents: contents) else { continue }
            tickets.append(ticket)
        }
        XCTAssertFalse(tickets.isEmpty)
        return tickets
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr449-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// CPU seconds the calling thread spends in `work`.
    private func threadCPU(_ work: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
    }

    private func report(_ name: String, perCall seconds: Double, callsPerMinute: Double) {
        print(String(
            format: "RR449 BENCH %@: %.1f us per call; %.1f ms/min (%.3f%% CPU) at %.0f calls/min",
            name, seconds * 1e6, seconds * callsPerMinute * 1_000, seconds * callsPerMinute * 100 / 60, callsPerMinute
        ))
    }
}
