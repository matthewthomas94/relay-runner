import SwiftUI
import XCTest
@testable import relay_runner

final class SessionWheelTests: XCTestCase {
    private let geometry = SessionWheelGeometry.self
    private func session(_ id: String) -> SessionWheelSession { .init(id: id, name: id) }
    private func projects(_ count: Int) -> [SessionWheelProject] {
        (0..<count).map { .init(id: "\($0)", name: "Project \($0)", path: "/projects/\($0)") }
    }

    func testSessionPositionsSurviveRefreshAndAnEmptySlotIsReused() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a"), session("b"), session("c")])
        model.hover(at: geometry.position(slot: 2, radius: 119))
        model.refresh(sessions: [session("c"), session("b")])
        XCTAssertNil(model.slots[0])
        XCTAssertEqual(model.slots[1]?.id, "b")
        XCTAssertEqual(model.slots[2]?.id, "c")
        XCTAssertEqual(model.hoveredSession?.id, "c")
        model.refresh(sessions: [session("d"), session("c"), session("b")])
        XCTAssertEqual(model.slots[0]?.id, "d")
        XCTAssertEqual(model.slots[2]?.id, "c")
        XCTAssertEqual(model.slots.count, 6)
    }

    func testEverySessionHasReachableOuterActionsAcrossTheRadialGap() {
        for slot in 0..<geometry.slotCount {
            let model = SessionWheelModel()
            model.refresh(sessions: (0..<6).map { session("\($0)") })
            model.hover(at: geometry.position(slot: slot, radius: 119))
            XCTAssertEqual(model.hoveredSlot, slot)
            model.hover(at: geometry.position(slot: slot, radius: 180))
            XCTAssertEqual(model.hoveredSession?.id, "\(slot)")
            XCTAssertNil(model.hoveredAction)
            for action in SessionWheelAction.allCases {
                let point = geometry.position(slot: slot, radius: geometry.actionRadius,
                                              offset: geometry.actionOffset(action))
                model.hover(at: point)
                XCTAssertEqual(model.hoveredSlot, slot)
                XCTAssertEqual(model.hoveredAction, action)
                let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius, subdivision: action.rawValue)
                XCTAssertTrue(shape.path(in: CGRect(origin: .zero, size: CGSize(width: 528, height: 528))).contains(point))
            }
        }
    }

    func testContourLabelsStayUprightAndFitInsideEveryThinActionSegment() {
        let bounds = CGRect(origin: .zero, size: CGSize(width: geometry.diameter, height: geometry.diameter))
        for slot in 0..<geometry.slotCount {
            for action in SessionWheelAction.allCases {
                let rotation = geometry.actionLabelRotation(slot: slot, action: action)
                let center = geometry.position(slot: slot, radius: geometry.actionRadius, offset: geometry.actionOffset(action))
                XCTAssertLessThanOrEqual(abs(rotation), .pi / 2, "Labels must never turn upside down")
                let radialAngle = CGFloat(slot) * geometry.sliceAngle + geometry.actionOffset(action)
                XCTAssertEqual(sin(radialAngle) * cos(rotation) - cos(radialAngle) * sin(rotation), 0, accuracy: 0.0001)
                let shape = SessionWheelSector(slot: slot, innerRadius: geometry.actionInnerRadius,
                                               outerRadius: geometry.actionOuterRadius, subdivision: action.rawValue)
                // Include padding in the check so the labels do not crowd the rounded edges.
                let halfWidth = geometry.actionLabelSize.width / 2 + 2
                let halfHeight = geometry.actionLabelSize.height / 2 + 2
                for x in [-halfWidth, halfWidth] {
                    for y in [-halfHeight, halfHeight] {
                        let corner = CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                                             y: center.y + x * sin(rotation) + y * cos(rotation))
                        XCTAssertTrue(shape.path(in: bounds).contains(corner), "Label clips at slot \(slot), action \(action)")
                    }
                }
            }
        }
    }

    func testCenterAndLeavingTheWheelClearHover() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.center)
        XCTAssertNil(model.hoveredSlot)
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: CGPoint(x: -30, y: -30))
        XCTAssertNil(model.hoveredSlot)
        XCTAssertNil(model.hoveredAction)
    }

    func testStoppedSessionLosesItsActionsImmediately() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius))
        XCTAssertEqual(model.hoveredAction, .recording)
        model.refresh(sessions: [])
        XCTAssertNil(model.hoveredSession)
        XCTAssertNil(model.hoveredAction)
    }

    func testReplacementSessionDoesNotInheritTheStoppedSessionsHoveredAction() {
        let model = SessionWheelModel()
        model.refresh(sessions: [session("a")])
        model.hover(at: geometry.position(slot: 0, radius: 119))
        model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius, offset: geometry.actionOffset(.stop)))
        XCTAssertEqual(model.hoveredAction, .stop)
        model.refresh(sessions: [session("b")])
        XCTAssertEqual(model.slots[0]?.id, "b")
        XCTAssertNil(model.hoveredSlot)
        XCTAssertNil(model.hoveredAction)
    }

    func testProjectPickerRequiresFreshMovementAndBackDoesNotCloseTheWheel() {
        let model = SessionWheelModel()
        model.projects = projects(2)
        let entry = geometry.position(slot: 0, radius: 119)
        model.hover(at: entry)
        model.showProjects(at: entry)
        model.hover(at: entry)
        XCTAssertTrue(model.pickingProject)
        XCTAssertNil(model.hoveredSlot)
        model.hover(at: CGPoint(x: entry.x + 10, y: entry.y))
        XCTAssertEqual(model.hoveredSlot, 0)
        XCTAssertNil(model.hoveredSession)
        XCTAssertTrue(model.back(at: entry))
        XCTAssertFalse(model.pickingProject)
        XCTAssertNil(model.hoveredSlot)
        XCTAssertFalse(model.back(at: entry))
    }

    func testProjectPaginationReachesEveryProjectAndClampsWhenListShrinks() {
        let model = SessionWheelModel()
        model.projects = projects(13)
        model.showProjects(at: geometry.center)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertEqual(model.visibleProjects.map(\.id), (0..<6).map(String.init))
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.visibleProjects.map(\.id), (6..<12).map(String.init))
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.visibleProjects.map(\.id), ["12"])
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.projectPage, 0)
        model.turnPage(-1, at: geometry.center)
        XCTAssertEqual(model.projectPage, 2)
        model.projects = projects(2)
        model.refresh(sessions: [])
        XCTAssertEqual(model.projectPage, 0)
        model.projects = []
        model.turnPage(1, at: geometry.center)
        XCTAssertEqual(model.projectPage, 0)
        XCTAssertTrue(model.visibleProjects.isEmpty)
    }

    func testWheelStartsAtCursorAndKeepsOuterControlsInsideEveryDisplayEdge() {
        let display = CGRect(x: -1600, y: -200, width: 1440, height: 900)
        let cursor = CGPoint(x: -900, y: 250)
        let centered = geometry.frame(at: cursor, visibleFrame: display)
        XCTAssertEqual(centered.midX, cursor.x)
        XCTAssertEqual(centered.midY, cursor.y)
        for x in [display.minX, display.maxX] {
            for y in [display.minY, display.maxY] {
                XCTAssertTrue(display.contains(geometry.frame(at: CGPoint(x: x, y: y), visibleFrame: display)))
            }
        }
        let small = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = geometry.frame(at: .zero, visibleFrame: small)
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 300))
        XCTAssertTrue(small.contains(frame))
    }

    func testRecordingCanStopOnlyItsOwnerAndRequiresReadyCaptureToStart() {
        XCTAssertTrue(SessionWheelRecording.canToggle(targetKey: "a", recording: false, recordingKey: "b", ready: true))
        XCTAssertTrue(SessionWheelRecording.canToggle(targetKey: "a", recording: true, recordingKey: "a", ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: "a", recording: true, recordingKey: "b", ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: nil, recording: false, recordingKey: nil, ready: true))
        XCTAssertFalse(SessionWheelRecording.canToggle(targetKey: "a", recording: false, recordingKey: nil, ready: false))
    }

    func testUnavailableActionsAndRecordingLabelsReflectSessionState() {
        var item = session("a")
        item.canPlay = false
        item.canRecord = false
        XCTAssertFalse(SessionWheelAction.message.isEnabled(for: item))
        XCTAssertFalse(SessionWheelAction.recording.isEnabled(for: item))
        XCTAssertTrue(SessionWheelAction.stop.isEnabled(for: item))
        item.unreadCount = 1
        XCTAssertEqual(SessionWheelAction.message.title(for: item), "Play message")
        item.unreadCount = 0
        XCTAssertEqual(SessionWheelAction.message.title(for: item), "Replay message")
        item.isRecording = true
        XCTAssertEqual(SessionWheelAction.recording.title(for: item), "Stop recording")
    }

    /// Set RELAY_WHEEL_RENDER_DIR to export the actual SwiftUI view for visual QA.
    @MainActor
    func testWheelRendering() throws {
        let model = SessionWheelModel()
        model.refresh(sessions: [
            .init(id: "relay", name: "Relay Runner", unreadCount: 2, isFocused: true),
            .init(id: "hidpress", name: "hidpress", isRecording: true),
            .init(id: "general", name: "general-tasks", canPlay: false)
        ])
        model.projects = ["Vial QMK", "Hidpress Web", "ESP32 Bridge", "Website", "Voice Notes", "Research", "Playground"]
            .enumerated().map { .init(id: "\($0.offset)", name: $0.element, path: "/\($0.offset)") }
        let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performAction: { _, _ in },
                                    back: {}, dismiss: {}, turnPage: { _ in })
        for state in ["sessions", "controls", "play-hover", "recording-controls", "projects", "last-page", "limit"]
            + (0..<geometry.slotCount).map({ "contour-\($0)" }) {
            switch state {
            case "controls": model.hover(at: geometry.position(slot: 0, radius: 119))
            case "play-hover":
                model.hover(at: geometry.position(slot: 0, radius: geometry.actionRadius, offset: geometry.actionOffset(.message)))
            case "recording-controls":
                model.hover(at: geometry.position(slot: 1, radius: 119))
                model.hover(at: geometry.position(slot: 1, radius: geometry.actionRadius))
            case "projects": model.showProjects(at: geometry.center)
            case "last-page": model.turnPage(1, at: geometry.center)
            case "limit": model.startUnavailableReason = "Session limit reached"
            default:
                if state.hasPrefix("contour-"), let slot = Int(state.suffix(1)) {
                    model.reset(at: geometry.center)
                    model.startUnavailableReason = nil
                    model.refresh(sessions: (0..<geometry.slotCount).map {
                        .init(id: "\($0)", name: "Project \($0 + 1)", isRecording: $0 == 1, canPlay: $0 != 2)
                    })
                    model.hover(at: geometry.position(slot: slot, radius: 119))
                }
            }
            let renderer = ImageRenderer(content: view
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .background(Color(red: 0.06, green: 0.07, blue: 0.09)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 1056)
            XCTAssertEqual(image.height, 1056)
            if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("\(state).png"))
            }
        }
    }
}
