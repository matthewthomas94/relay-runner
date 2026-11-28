import AppKit
import XCTest
@testable import relay_runner

final class CapsLockGestureTests: XCTestCase {
    func testCancelledManualRecordingCanStartWithOneClickAgain() {
        let gesture = CapsLockGesture(
            activationKey: "f13",
            globalMonitorInstaller: { _, _ in nil },
            localMonitorInstaller: { _, _ in nil },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in }
        )
        gesture.toggleActivation()
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        gesture.reset()
        XCTAssertNil(gesture.poll(currentSegment: ""))
        gesture.toggleActivation()
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
    }

    func testGlobalModifierMonitorRetriesAfterInitialFailureWithoutDuplicates() {
        var globalInstallCount = 0
        var localInstallCount = 0
        var removedMonitorCount = 0
        var diagnostics: [String] = []
        var recoveredGlobalHandler: ((NSEvent) -> Void)?
        let globalToken = NSObject()
        let localToken = NSObject()

        do {
            let gesture = CapsLockGesture(
                globalMonitorInstaller: { _, handler in
                    globalInstallCount += 1
                    guard globalInstallCount > 1 else { return nil }
                    recoveredGlobalHandler = handler
                    return globalToken
                },
                localMonitorInstaller: { _, _ in
                    localInstallCount += 1
                    return localToken
                },
                monitorRemover: { _ in
                    removedMonitorCount += 1
                },
                diagnosticLogger: { diagnostics.append($0) }
            )

            XCTAssertEqual(globalInstallCount, 1)
            XCTAssertEqual(localInstallCount, 1)

            gesture.retryMissingGlobalMonitors()
            XCTAssertEqual(globalInstallCount, 2)
            XCTAssertTrue(diagnostics.contains { $0.contains("global monitor recovered") })
            XCTAssertTrue(diagnostics.contains {
                $0.contains("identity=modifier-global") && $0.contains("generation=")
            })

            recoveredGlobalHandler?(modifierEvent(flags: [.option], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [.option], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [], keyCode: 58))
            guard case .play? = gesture.poll(currentSegment: "") else {
                return XCTFail("Recovered global monitor did not deliver double-tap Option")
            }

            gesture.retryMissingGlobalMonitors()
            XCTAssertEqual(globalInstallCount, 2)
        }

        XCTAssertEqual(removedMonitorCount, 2)
        XCTAssertTrue(diagnostics.contains { $0.contains("monitors stopped count=2") })
    }

    func testStoppedVoiceMonitorCannotReplayAfterNoteModeTakesOwnership() {
        var global: ((NSEvent) -> Void)?
        var local: ((NSEvent) -> NSEvent?)?
        var removals = 0
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, handler in global = handler; return NSObject() },
            localMonitorInstaller: { _, handler in local = handler; return NSObject() },
            monitorRemover: { _ in removals += 1 }
        )
        gesture.stopMonitoring()
        sendDoubleTap(.option, keyCode: 58, to: local)
        global?(modifierEvent(flags: [.option], keyCode: 58))
        XCTAssertNil(gesture.poll(currentSegment: ""))
        XCTAssertEqual(removals, 2)
    }

    func testForegroundModifierDownUpEmitsExactlyOnePlay() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        sendDoubleTap(.option, keyCode: 58, to: localHandler)

        guard case .play? = gesture.poll(currentSegment: "") else {
            return XCTFail("Foreground local monitor did not emit play")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testControlStopThenOptionReplayPreservesGestureOrdering() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        sendDoubleTap(.control, keyCode: 59, to: localHandler)
        guard case .cancel? = gesture.poll(currentSegment: "") else {
            return XCTFail("Double-tap Control did not emit stop")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))

        sendDoubleTap(.option, keyCode: 58, to: localHandler)
        guard case .play? = gesture.poll(currentSegment: "") else {
            return XCTFail("First Option gesture after stop did not emit replay")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testConfirmationConsumesOptionDoubleTapWithoutPlayback() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )
        let stateMachine = StateMachine()
        stateMachine.setActionGlow(awaitingConfirmation: ConfirmationPrompt(
            summary: "Confirm test action",
            risk: "medium",
            requestId: "confirmation-1"
        ))
        var confirmations: [Bool] = []
        gesture.stateMachine = stateMachine
        gesture.confirmationResolver = { confirmations.append($0) }

        sendDoubleTap(.option, keyCode: 58, to: localHandler)

        XCTAssertEqual(confirmations, [true])
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    // MARK: - Hold Control and Option to talk

    private func holdGesture(
        flags: @escaping () -> NSEvent.ModifierFlags,
        local: @escaping (@escaping (NSEvent) -> NSEvent?) -> Void = { _ in }
    ) -> CapsLockGesture {
        CapsLockGesture(
            activationKey: CapsLockGesture.holdActivationKey,
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in local(handler); return NSObject() },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in },
            modifierState: flags
        )
    }

    func testHoldingControlAndOptionRecordsAndReleasingSends() {
        var flags: NSEvent.ModifierFlags = []
        let gesture = holdGesture(flags: { flags })
        XCTAssertNil(gesture.poll(currentSegment: ""))
        // Neither key alone, nor the pair with Command or Shift, opens the mic.
        for other: NSEvent.ModifierFlags in [[.control], [.option], [.control, .option, .command], [.control, .option, .shift]] {
            flags = other
            XCTAssertNil(gesture.poll(currentSegment: ""), "\(other)")
        }
        flags = [.control, .option, .capsLock]
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        XCTAssertTrue(gesture.isActivationHeld)
        XCTAssertNil(gesture.poll(currentSegment: ""))
        Thread.sleep(forTimeInterval: 0.55)
        XCTAssertNil(gesture.poll(currentSegment: ""))
        XCTAssertTrue(gesture.isRecording)
        flags = [.option]
        XCTAssertEqual(gesture.poll(currentSegment: "hello"), .stopRecording(text: "hello"))
        XCTAssertFalse(gesture.isRecording)
    }

    func testAKeyPressedDuringTheHoldDiscardsItUntilBothKeysAreReleased() {
        var flags: NSEvent.ModifierFlags = []
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = holdGesture(flags: { flags }, local: { localHandler = $0 })
        flags = [.control, .option]
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        // Control-Option-Left is a shortcut, not a message.
        _ = localHandler?(keyDownEvent(flags: [.control, .option], keyCode: 123))
        XCTAssertEqual(gesture.poll(currentSegment: "spoken"), .discard)
        XCTAssertFalse(gesture.isRecording)
        XCTAssertNil(gesture.poll(currentSegment: "spoken"), "still held: nothing restarts")
        flags = []
        XCTAssertNil(gesture.poll(currentSegment: "spoken"), "released: nothing is sent")
        flags = [.control, .option]
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
    }

    func testHoldingTheTwoKeysRepeatedlyIsNotADoubleTapOfEither() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = holdGesture(flags: { [] }, local: { localHandler = $0 })
        for _ in 0..<3 {
            _ = localHandler?(modifierEvent(flags: [.option], keyCode: 58))
            _ = localHandler?(modifierEvent(flags: [.option, .control], keyCode: 59))
            _ = localHandler?(modifierEvent(flags: [.option], keyCode: 59))
            _ = localHandler?(modifierEvent(flags: [], keyCode: 58))
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
        // Each key alone still double-taps.
        sendDoubleTap(.option, keyCode: 58, to: localHandler)
        XCTAssertEqual(gesture.poll(currentSegment: ""), .play)
        sendDoubleTap(.control, keyCode: 59, to: localHandler)
        XCTAssertEqual(gesture.poll(currentSegment: ""), .cancel)
    }

    func testShiftOptionAndShiftControlSwitchAgentsWithoutPlayOrCancel() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = holdGesture(flags: { [] }, local: { localHandler = $0 })
        for _ in 0..<2 {
            _ = localHandler?(modifierEvent(flags: [.shift], keyCode: 56))
            _ = localHandler?(modifierEvent(flags: [.shift, .option], keyCode: 58))
            _ = localHandler?(modifierEvent(flags: [.shift], keyCode: 58))
            _ = localHandler?(modifierEvent(flags: [], keyCode: 56))
            XCTAssertEqual(gesture.poll(currentSegment: ""), .cycleAgent(.forward))
        }
        for _ in 0..<2 {
            _ = localHandler?(modifierEvent(flags: [.control], keyCode: 59))
            _ = localHandler?(modifierEvent(flags: [.control, .shift], keyCode: 56))
            _ = localHandler?(modifierEvent(flags: [.control], keyCode: 56))
            _ = localHandler?(modifierEvent(flags: [], keyCode: 59))
            XCTAssertEqual(gesture.poll(currentSegment: ""), .cycleAgent(.backward))
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testShiftOptionTypingDoesNotSwitchAgents() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = holdGesture(flags: { [] }, local: { localHandler = $0 })
        _ = localHandler?(modifierEvent(flags: [.shift, .option], keyCode: 58))
        _ = localHandler?(keyDownEvent(flags: [.shift, .option], keyCode: 40))
        _ = localHandler?(modifierEvent(flags: [], keyCode: 58))
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    /// Hold to talk is the default on a new install; a config written before
    /// the setting existed keeps Caps Lock.
    func testActivationModeDefaultsToHoldOnlyOnAFreshInstall() {
        XCTAssertTrue(SttConfig.freshInstall().holdsToTalk)
        XCTAssertFalse(SttConfig().holdsToTalk)
        XCTAssertEqual(AwarenessSettingsTab.activationOptions.map(\.value), [
            SttConfig.ActivationMode.hold, SttConfig.ActivationMode.capsLock,
        ])
        XCTAssertEqual(OverlayController.sendHint(holdsToTalk: true), "Release Control and Option to send")
        XCTAssertEqual(OverlayController.sendHint(holdsToTalk: false), "Press Caps Lock to stop and send")
        XCTAssertTrue(OverlayController.sessionPromptBody(holdsToTalk: true).hasSuffix("Hold Control and Option to dismiss"))
        XCTAssertTrue(OverlayController.sessionPromptBody(holdsToTalk: false).hasSuffix("Press Caps Lock to dismiss"))
    }

    /// The tutorial's help names the keys the user was asked to hold, and a
    /// press that never arrived is not blamed on a permission.
    func testTutorialRecordingHelpNamesTheHoldKeys() {
        var probe = OnboardingTutorialRecordingProbe()
        probe.holdsToTalk = true
        probe.keyboardAccess = .denied
        probe.capsLock = CapsLockKeyboardConfiguration(switchesInputSource: true, remapped: true)
        let silent = OnboardingTutorialRecordingHelp.diagnose(.noCapsLockEvents, probe: probe)
        XCTAssertTrue(silent.message.contains("Control and Option held together"))
        XCTAssertNil(silent.fix)
        let pressed = OnboardingTutorialRecordingHelp.diagnose(.pressedWithoutRecording, probe: probe)
        XCTAssertTrue(pressed.message.hasPrefix("Control and Option were pressed"))
        XCTAssertFalse(pressed.message.contains("Caps Lock"))
        let hold = OnboardingSessionControlsTutorial.keycapPhase(for: .holdControl, at: 1)
        XCTAssertEqual(hold.scale, 0.94, "the key stays down through the hold")
        XCTAssertEqual(OnboardingSessionControlsTutorial.keycapPhase(for: .holdOption, at: 2.5).scale, 1)
    }

    func testOptionModifiedTypingDoesNotEmitPlayback() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        for keyCode: UInt16 in [0, 1] {
            _ = localHandler?(modifierEvent(flags: [.option], keyCode: 58))
            _ = localHandler?(keyDownEvent(flags: [.option], keyCode: keyCode))
            _ = localHandler?(modifierEvent(flags: [], keyCode: 58))
        }

        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    /// While Relay Remote holds the mic the loop only takes these, so the
    /// agent switch must be takeable without a full poll, and only once.
    func testAgentSwitchCanBeTakenWithoutPolling() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        _ = localHandler?(modifierEvent(flags: [.shift], keyCode: 56))
        _ = localHandler?(modifierEvent(flags: [.shift, .option], keyCode: 58))
        _ = localHandler?(modifierEvent(flags: [.shift], keyCode: 58))
        _ = localHandler?(modifierEvent(flags: [], keyCode: 56))

        XCTAssertEqual(gesture.takeAgentCycle(), .forward)
        XCTAssertNil(gesture.takeAgentCycle())
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    private func sendDoubleTap(
        _ modifier: NSEvent.ModifierFlags,
        keyCode: UInt16,
        to handler: ((NSEvent) -> NSEvent?)?
    ) {
        _ = handler?(modifierEvent(flags: modifier, keyCode: keyCode))
        _ = handler?(modifierEvent(flags: [], keyCode: keyCode))
        _ = handler?(modifierEvent(flags: modifier, keyCode: keyCode))
        _ = handler?(modifierEvent(flags: [], keyCode: keyCode))
    }

    private func modifierEvent(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func keyDownEvent(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
