import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

@MainActor
final class SettingsInputControlsTests: XCTestCase {
    func testPickerMenuMatchesNarrowFieldAndResizes() throws {
        let window = host(HStack(spacing: 8) {
            SettingsMenuPicker("Voice", selection: .constant(0), options: [
                ("Puck (American Male)", 0), ("George (British Male)", 1),
                ("Isabella (British Female)", 2), ("Sky (American Female)", 3),
            ])
            SettingsActionButton(title: "Preview", systemImage: "play.fill", prominence: .icon) {}
        }, size: NSSize(width: 280, height: 34))
        defer { window.close() }

        try click(NSPoint(x: 100, y: 17), in: window)
        let popup = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        XCTAssertEqual(popup.frame.minX, window.frame.minX, accuracy: 0.5)
        XCTAssertEqual(popup.frame.maxX, window.frame.maxX - 36, accuracy: 0.5)
        XCTAssertEqual(popup.frame.height, 146, accuracy: 0.5)
        XCTAssertEqual(window.frame.minY - popup.frame.maxY, 8, accuracy: 0.5)

        window.setContentSize(NSSize(width: 360, height: 34))
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        XCTAssertEqual(popup.frame.minX, window.frame.minX, accuracy: 0.5)
        XCTAssertEqual(popup.frame.maxX, window.frame.maxX - 36, accuracy: 0.5)
        XCTAssertEqual(popup.frame.height, 146, accuracy: 0.5)
    }

    func testPickerOpensAndCommitsSelection() throws {
        var selection = 3
        let window = host(SettingsMenuPicker("Effort", selection: Binding(get: { selection }, set: { selection = $0 }),
                                             options: effortOptions), size: NSSize(width: 280, height: 34))
        defer { window.close() }
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        try click(NSPoint(x: 140, y: 17), in: window)
        let popup = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains($0.windowNumber) && $0.isVisible })
        defer { popup.orderOut(nil) }
        XCTAssertTrue(popup.styleMask.contains(.borderless))
        XCTAssertEqual(window.frame.minY - popup.frame.maxY, 8, accuracy: 0.5)
        if let directory = ProcessInfo.processInfo.environment["RELAY_SETTINGS_RENDER_DIR"], let view = popup.contentView?.superview {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("settings-dropdown.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        try sendKey(125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), to: popup)
        try sendKey(36, characters: "\r", to: popup)
        settle()
        XCTAssertEqual(selection, 4)
        XCTAssertFalse(popup.isVisible)
    }

    func testMenuKeyboardSelectionAndEscape() throws {
        var selection = 1
        var dismissals = 0
        let window = host(SettingsMenuOptions(
            title: "Effort", selection: Binding(get: { selection }, set: { selection = $0 }),
            options: [("Low", 0), ("Medium", 1), ("High", 2)],
            dismiss: { dismissals += 1 }
        ), size: NSSize(width: 280, height: 112))
        defer { window.close() }
        window.makeKey()
        settle()
        try sendKey(125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), to: window)
        try sendKey(36, characters: "\r", to: window)
        XCTAssertEqual(selection, 2)
        XCTAssertEqual(dismissals, 1)
        try sendKey(53, characters: "\u{1b}", to: window)
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(selection, 2, "Escape must not change the selected value")
    }

    func testPickerDismissesAndReopensWithoutChangingSelection() throws {
        var selection = 3
        let window = host(VStack(spacing: 0) {
            SettingsMenuPicker("Effort", selection: Binding(get: { selection }, set: { selection = $0 }),
                               options: effortOptions)
            Color.clear.frame(height: 66)
        }, size: NSSize(width: 280, height: 100))
        defer { window.close() }
        let field = NSPoint(x: 140, y: 83)

        try click(field, in: window)
        let firstPopup = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        try sendKey(53, characters: "\u{1b}", to: firstPopup)
        settle()
        XCTAssertFalse(firstPopup.isVisible)

        try click(field, in: window)
        let secondPopup = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        try click(NSPoint(x: 140, y: 10), in: window, throughApplication: true)
        settle()
        XCTAssertFalse(secondPopup.isVisible)

        try click(field, in: window)
        let thirdPopup = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        try click(field, in: window, throughApplication: true)
        settle()
        XCTAssertFalse(thirdPopup.isVisible)
        XCTAssertFalse(window.childWindows?.contains { $0.isVisible } ?? false, "Clicking the field must not reopen the menu")
        XCTAssertEqual(selection, 3)

        try click(field, in: window)
        let finalPopup = try XCTUnwrap(window.childWindows?.first { $0.isVisible })
        window.close()
        settle()
        settle()
        XCTAssertFalse(finalPopup.isVisible)
    }

    func testCheckboxTogglesAndRespectsDisabledState() throws {
        var enabledValue = false
        var disabledValue = false
        let window = host(VStack(spacing: 0) {
            Toggle("Enabled option", isOn: Binding(get: { enabledValue }, set: { enabledValue = $0 }))
                .frame(width: 300, height: 40)
            Toggle("Disabled option", isOn: Binding(get: { disabledValue }, set: { disabledValue = $0 }))
                .disabled(true)
                .frame(width: 300, height: 40)
        }.toggleStyle(SettingsCheckboxStyle()), size: NSSize(width: 300, height: 80))
        defer { window.close() }
        try click(NSPoint(x: 150, y: 60), in: window)
        XCTAssertTrue(enabledValue)
        try click(NSPoint(x: 150, y: 20), in: window)
        XCTAssertFalse(disabledValue)
    }

    func testStepperDisablesButtonsAtBounds() throws {
        var value = 1
        let window = host(SettingsStepper(
            title: "Budget", value: Binding(get: { value }, set: { value = $0 }), range: 1...2, unit: "MB"
        ), size: NSSize(width: 184, height: 34))
        defer { window.close() }
        try click(NSPoint(x: 14, y: 17), in: window)
        XCTAssertEqual(value, 1)
        try click(NSPoint(x: 170, y: 17), in: window)
        XCTAssertEqual(value, 2)
        try click(NSPoint(x: 170, y: 17), in: window)
        XCTAssertEqual(value, 2)
    }

    func testSliderSnapsPointerPositionsAndStepsInsideItsRange() {
        let range = 0.5...2.0
        XCTAssertEqual(SettingsSlider.value(atX: 196, width: 200, in: range, step: 0.1), 2.0)
        XCTAssertEqual(SettingsSlider.value(atX: 2, width: 200, in: range, step: 0.1), 0.5)
        XCTAssertEqual(SettingsSlider.value(atX: 150, width: 200, in: range, step: 0.1), 1.7, "Snaps to the nearest step")
        XCTAssertEqual(SettingsSlider.snapped(1.3 + 0.1, in: range, step: 0.1), 1.4, "No floating-point drift")
        XCTAssertEqual(SettingsSlider.snapped(2.05, in: range, step: 0.1), 2.0, "Stays inside the range")
        XCTAssertEqual(SettingsSlider.snapped(0.1 + 0.05 * 3, in: 0.1...1.0, step: 0.05), 0.25)
    }

    func testRenderSettingsControls() throws {
        guard let directory = ProcessInfo.processInfo.environment["RELAY_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set RELAY_SETTINGS_RENDER_DIR to export the native control fixture")
        }
        let fixture = SettingsStack {
            SettingsSection("Activation") {
                SettingsControlRow("Activation Key") {
                    KeyCaptureView(label: "Activation Key", showsLabel: false, value: .constant("Caps Lock"))
                }
            }
            SettingsSection("Personal files") {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    SettingsActionButton(title: "Open local files", systemImage: "folder") {}
                    SettingsActionButton(title: "Refresh", systemImage: "arrow.clockwise") {}
                }
                SettingsControlRow("Local cache budget", description: "Unsynced, pinned and active files are preserved.") {
                    SettingsStepper(title: "Local cache budget", value: .constant(256), range: 1...100_000, unit: "MB")
                }
                SettingsDivider()
                SettingsControlRow("Keep recently used files") {
                    SettingsStepper(title: "Keep recently used files", value: .constant(30), range: 0...3650, unit: "days")
                }
            }
            SettingsSection("Options") {
                SettingsControlRow("Enabled") { Toggle("Enabled", isOn: .constant(true)) }
                SettingsDivider()
                SettingsControlRow("Unchecked") { Toggle("Unchecked", isOn: .constant(false)) }
                SettingsDivider()
                SettingsControlRow("Unavailable") { Toggle("Unavailable", isOn: .constant(false)).disabled(true) }
            }
            SettingsSection("Playback") {
                SettingsControlRow("Playback Mode") {
                    SettingsSegmentedPicker("Playback Mode", selection: .constant(false), options: [
                        (label: "Auto-play", value: true),
                        (label: "Queue", value: false),
                    ])
                }
                SettingsDivider()
                SettingsControlRow("Speech Speed") {
                    SettingsSlider(value: .constant(1.3), in: 0.5...2.0, step: 0.1, label: "1.3x")
                }
                SettingsDivider()
                SettingsControlRow("Intensity") {
                    SettingsSlider(value: .constant(0.25), in: 0.1...1.0, step: 0.05, label: "25%").disabled(true)
                }
            }
            SettingsSection("Orchestrator Effort") {
                HStack(alignment: .top) {
                    SettingsMenuPicker("Effort", selection: .constant(3), options: effortOptions)
                    SettingsMenuOptions(title: "Effort", selection: .constant(3), options: effortOptions, dismiss: {})
                }
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(BoardDarkSurfaceStyle.panelFill)
        .environment(\.colorScheme, .dark)
        let window = host(fixture, size: NSSize(width: 760, height: 900))
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("settings-controls.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private var effortOptions: [(label: String, value: Int)] {
        [("Low", 0), ("Medium", 1), ("High", 2), ("Extra High", 3), ("Max", 4)]
    }

    private func host<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let window = ControlTestWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.transaction { $0.disablesAnimations = true })
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return window
    }

    private func click(_ point: NSPoint, in window: NSWindow, throughApplication: Bool = false) throws {
        if !throughApplication { window.makeKey() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            if throughApplication { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
        settle()
    }

    private func sendKey(_ code: UInt16, characters: String, to window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )))
        settle()
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}

private final class ControlTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
