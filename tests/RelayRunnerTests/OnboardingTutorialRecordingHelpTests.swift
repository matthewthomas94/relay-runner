import AppKit
import XCTest
@testable import relay_runner

/// RR-516: Caps Lock did nothing on the tutorial's recording step on a fresh
/// install. These cover the speech-model gate, the Caps Lock diagnostics, the
/// click fallback and the diagnostic logging, all with fakes.
final class OnboardingTutorialRecordingHelpTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        OnboardingResumeState.clear()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        OnboardingResumeState.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Caps Lock keyboard configuration

    func testCapsLockSwitchesInputSourceWithSeveralSourcesUnlessTurnedOff() {
        let abc: [String: Any] = ["InputSourceKind": "Keyboard Layout", "KeyboardLayout Name": "ABC"]
        let pinyin: [String: Any] = ["InputSourceKind": "Keyboard Input Method", "Bundle ID": "com.apple.inputmethod.SCIM"]
        let pinyinMode: [String: Any] = ["InputSourceKind": "Input Mode", "Bundle ID": "com.apple.inputmethod.SCIM"]
        let palette: [String: Any] = ["InputSourceKind": "Non Keyboard Input Method", "Bundle ID": "com.apple.CharacterPaletteIM"]

        // macOS stores the switch only after the user changes it; it defaults on.
        XCTAssertTrue(CapsLockKeyboardConfiguration.switchesInputSource(
            romanSwitchState: nil, enabledInputSources: [abc, pinyin, pinyinMode]))
        XCTAssertTrue(CapsLockKeyboardConfiguration.switchesInputSource(
            romanSwitchState: 1, enabledInputSources: [abc, pinyin]))
        XCTAssertFalse(CapsLockKeyboardConfiguration.switchesInputSource(
            romanSwitchState: 0, enabledInputSources: [abc, pinyin]))
        // One keyboard source: nothing to switch to, even with palettes enabled.
        XCTAssertFalse(CapsLockKeyboardConfiguration.switchesInputSource(
            romanSwitchState: 1, enabledInputSources: [abc, palette]))
    }

    func testCapsLockRemapDetectsModifierKeysMapping() {
        let caps = CapsLockKeyboardConfiguration.capsLockUsage
        let toControl: [String: Any] = [
            "HIDKeyboardModifierMappingSrc": NSNumber(value: caps),
            "HIDKeyboardModifierMappingDst": NSNumber(value: Int64(30064771296)),
        ]
        let identity: [String: Any] = [
            "HIDKeyboardModifierMappingSrc": NSNumber(value: caps),
            "HIDKeyboardModifierMappingDst": NSNumber(value: caps),
        ]
        let optionToCommand: [String: Any] = [
            "HIDKeyboardModifierMappingSrc": NSNumber(value: Int64(30064771298)),
            "HIDKeyboardModifierMappingDst": NSNumber(value: Int64(30064771299)),
        ]

        XCTAssertTrue(CapsLockKeyboardConfiguration.remapped(mappings: [optionToCommand, toControl]))
        XCTAssertFalse(CapsLockKeyboardConfiguration.remapped(mappings: [identity, optionToCommand]))
        XCTAssertFalse(CapsLockKeyboardConfiguration.remapped(mappings: []))
    }

    // MARK: - Watch

    func testWatchReportsNoCapsLockEventsAfterSilenceGrace() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var watch = OnboardingTutorialRecordingWatch(startedAt: start, baseline: Probe())

        XCTAssertNil(watch.observe(Probe(), now: start.addingTimeInterval(9.9)))
        XCTAssertEqual(watch.observe(Probe(), now: start.addingTimeInterval(10)), .noCapsLockEvents)
    }

    func testWatchReportsPressWithoutRecordingAfterPressGrace() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var watch = OnboardingTutorialRecordingWatch(startedAt: start, baseline: Probe())
        var on = Probe()
        on.capsLockOn = true

        XCTAssertNil(watch.observe(on, now: start.addingTimeInterval(8)))
        XCTAssertNil(watch.observe(on, now: start.addingTimeInterval(10.9)))
        XCTAssertEqual(watch.observe(on, now: start.addingTimeInterval(11)), .pressedWithoutRecording)
    }

    func testWatchCountsCapsLockKeyEventsWithoutStateChangeAsPress() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var watch = OnboardingTutorialRecordingWatch(startedAt: start, baseline: Probe())
        var event = Probe()
        event.capsLockKeyEvents = 2

        XCTAssertNil(watch.observe(event, now: start.addingTimeInterval(1)))
        XCTAssertEqual(watch.firstPressAt, start.addingTimeInterval(1))
        XCTAssertEqual(watch.observe(event, now: start.addingTimeInterval(4)), .pressedWithoutRecording)
    }

    // MARK: - Diagnosis

    func testDiagnosisNamesSpecificReasonWithFix() {
        typealias Help = OnboardingTutorialRecordingHelp
        func diagnose(_ symptom: OnboardingTutorialRecordingWatch.Symptom,
                      _ change: (inout Probe) -> Void) -> Help {
            var probe = Probe()
            change(&probe)
            return Help.diagnose(symptom, probe: probe)
        }

        let micMissing = diagnose(.pressedWithoutRecording) {
            $0.microphone = .denied
            $0.speech = .notStarted
        }
        XCTAssertEqual(micMissing.reason, .microphoneNotGranted)
        XCTAssertEqual(micMissing.fix, .openSettings(.microphone))

        let failed = diagnose(.pressedWithoutRecording) { $0.speech = .failed("Could not reach Hugging Face") }
        XCTAssertEqual(failed.reason, .speechModelFailed)
        XCTAssertEqual(failed.fix, .retrySpeechSetup)

        let preparing = diagnose(.pressedWithoutRecording) { $0.speech = .preparing("Downloading 3/9 (12%)") }
        XCTAssertEqual(preparing.reason, .speechModelPreparing)
        XCTAssertNil(preparing.fix)

        let switching = diagnose(.noCapsLockEvents) { $0.capsLock.switchesInputSource = true }
        XCTAssertEqual(switching.reason, .capsLockSwitchesInputSource)
        XCTAssertEqual(switching.fix, .openSettings(.keyboard))

        let remapped = diagnose(.noCapsLockEvents) { $0.capsLock.remapped = true }
        XCTAssertEqual(remapped.reason, .capsLockRemapped)
        XCTAssertEqual(remapped.fix, .openSettings(.keyboard))

        let access = diagnose(.noCapsLockEvents) { $0.keyboardAccess = .denied }
        XCTAssertEqual(access.reason, .keyboardAccessMissing)
        XCTAssertEqual(access.fix, .openSettings(.inputMonitoring))

        let noMic = diagnose(.pressedWithoutRecording) { $0.microphoneCaptureReady = false }
        XCTAssertEqual(noMic.reason, .microphoneUnavailable)
        XCTAssertEqual(noMic.fix, .openSettings(.sound))

        XCTAssertEqual(diagnose(.pressedWithoutRecording) { _ in }.reason, .recordingDidNotStart)
        XCTAssertEqual(diagnose(.noCapsLockEvents) { _ in }.reason, .keyMonitoringUnverified)
        XCTAssertEqual(Help.Fix.openSettings(.keyboard).title, "Open Keyboard Settings")
        XCTAssertEqual(
            Help.SettingsPane.microphone.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    // MARK: - Fixed cause: tutorial reached Caps Lock before speech was ready

    func testTutorialIntroWaitsForSpeechModelBeforeRecordingStep() {
        var readiness = SetupRuntimeReadiness.preparing("Downloading Parakeet 1/9 (4%)")
        var logs: [String] = []
        let intro = RecordingIntroPresenter()
        let controller = makeController(
            intro: intro,
            speechReadiness: { readiness },
            checkInterval: 0.01,
            log: { logs.append($0) }
        )
        resume(at: .tutorialIntro)

        controller.showIfNeeded()
        waitForMainQueue(after: 0.1)

        // Before the fix the intro advanced to "Turn Caps Lock on" while the
        // gesture loop was still waiting on the model download.
        XCTAssertEqual(intro.presentations.map(\.screen), [.intro, .intro])
        XCTAssertEqual(intro.presentations.last?.message, OnboardingController.tutorialSpeechPreparingMessage)
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialIntro)
        XCTAssertTrue(logs.contains { $0.contains("waiting for speech model") })

        readiness = .ready
        waitForMainQueue(after: 0.1)

        XCTAssertEqual(intro.presentations.map(\.screen), [.intro, .intro, .recording])
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)
    }

    func testTutorialSpeechSetupFailureOffersRetryThatRestartsSpeech() {
        var readiness = SetupRuntimeReadiness.failed("Could not reach Hugging Face")
        var retries = 0
        let intro = RecordingIntroPresenter()
        let controller = makeController(
            intro: intro,
            speechReadiness: { readiness },
            retrySpeech: {
                retries += 1
                readiness = .ready
            },
            checkInterval: 0.01
        )
        resume(at: .tutorialIntro)

        controller.showIfNeeded()
        waitForMainQueue(after: 0.05)
        XCTAssertEqual(intro.presentations.map(\.screen), [.intro, .sessionRetry])

        intro.retryAction?()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(retries, 1)
        XCTAssertEqual(intro.presentations.map(\.screen), [.intro, .sessionRetry, .intro, .recording])
    }

    // MARK: - Recording step diagnostics

    func testPressWhileSpeechModelLoadingShowsReasonOnRecordingStep() {
        let clock = FakeClock()
        var probe = Probe()
        probe.speech = .preparing("Compiling Parakeet")
        var logs: [String] = []
        let intro = RecordingIntroPresenter()
        let controller = makeController(intro: intro, probe: { probe }, clock: clock, log: { logs.append($0) })
        resume(at: .tutorialRecording)
        controller.showIfNeeded()
        XCTAssertEqual(intro.presentations.map(\.screen), [.recording])
        XCTAssertNil(intro.presentations.last?.recordingHelp)

        clock.advance(2)
        probe.capsLockOn = true
        controller.checkTutorialRecording()
        clock.advance(2.5)
        controller.checkTutorialRecording()
        XCTAssertEqual(intro.presentations.count, 1)

        clock.advance(0.5)
        controller.checkTutorialRecording()

        let help = intro.presentations.last?.recordingHelp
        XCTAssertEqual(intro.presentations.map(\.screen), [.recording, .recording])
        XCTAssertEqual(help?.symptom, .pressedWithoutRecording)
        XCTAssertEqual(help?.reason, .speechModelPreparing)
        XCTAssertTrue(logs.contains { $0.contains("Caps Lock activity seen") })
        XCTAssertTrue(logs.contains {
            $0.contains("recording help symptom=pressedWithoutRecording reason=speechModelPreparing")
                && $0.contains("speech=preparing")
        })

        // The same reason is not re-presented on every tick.
        clock.advance(1)
        controller.checkTutorialRecording()
        XCTAssertEqual(intro.presentations.count, 2)
    }

    func testNoCapsLockEventsWithInputSourceSwitchingShowsKeyboardFix() {
        let clock = FakeClock()
        var probe = Probe()
        probe.capsLock.switchesInputSource = true
        var openedURLs: [URL] = []
        var externalWindows = 0
        let intro = RecordingIntroPresenter()
        let controller = makeController(
            intro: intro,
            probe: { probe },
            clock: clock,
            openSettings: { openedURLs.append($0) },
            onOpenExternalWindow: { externalWindows += 1 }
        )
        resume(at: .tutorialRecording)
        controller.showIfNeeded()

        clock.advance(OnboardingTutorialRecordingWatch.silenceGrace)
        controller.checkTutorialRecording()

        let help = intro.presentations.last?.recordingHelp
        XCTAssertEqual(help?.symptom, .noCapsLockEvents)
        XCTAssertEqual(help?.reason, .capsLockSwitchesInputSource)
        XCTAssertEqual(help?.fix, .openSettings(.keyboard))

        let presentationsBeforeFix = intro.presentations.count
        intro.recordingActions?.fix?()
        XCTAssertEqual(intro.dismissals, 1, "the tutorial steps aside before System Settings opens")
        XCTAssertEqual(openedURLs, [OnboardingTutorialRecordingHelp.SettingsPane.keyboard.url])
        XCTAssertEqual(externalWindows, 1)

        // RR-514: coming back to Relay Runner shows the same tutorial step.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        waitForMainQueue(after: 0.05)
        XCTAssertEqual(intro.presentations.count, presentationsBeforeFix + 1)
        XCTAssertEqual(intro.presentations.last?.screen, .recording)
        XCTAssertEqual(intro.presentations.last?.recordingHelp?.reason, .capsLockSwitchesInputSource)
    }

    func testSpeechFailureFixOnRecordingStepRetriesSpeechSetup() {
        let clock = FakeClock()
        var probe = Probe()
        probe.speech = .failed("Model files failed verification")
        var retries = 0
        let intro = RecordingIntroPresenter()
        let controller = makeController(
            intro: intro,
            probe: { probe },
            retrySpeech: { retries += 1 },
            clock: clock
        )
        resume(at: .tutorialRecording)
        controller.showIfNeeded()

        clock.advance(1)
        probe.capsLockKeyEvents = 1
        controller.checkTutorialRecording()
        clock.advance(OnboardingTutorialRecordingWatch.pressGrace)
        controller.checkTutorialRecording()

        XCTAssertEqual(intro.presentations.last?.recordingHelp?.reason, .speechModelFailed)
        intro.recordingActions?.fix?()
        XCTAssertEqual(retries, 1)
    }

    // MARK: - Click fallback

    func testClickFallbackStartsAndStopsRecordingOnBothRecordingSteps() {
        var toggles = 0
        var logs: [String] = []
        let intro = RecordingIntroPresenter()
        let controller = makeController(
            intro: intro,
            probe: { Probe() },
            toggleRecording: { toggles += 1 },
            log: { logs.append($0) }
        )
        resume(at: .tutorialRecording)
        controller.showIfNeeded()

        XCTAssertNotNil(intro.recordingActions)
        XCTAssertNil(intro.recordingActions?.fix)
        intro.recordingActions?.toggleRecording()
        XCTAssertEqual(toggles, 1)

        // The engine reports the recording the click started.
        controller.noteTutorialRecordingStarted()
        XCTAssertEqual(intro.presentations.map(\.screen), [.recording, .recordingActive])
        intro.recordingActions?.toggleRecording()
        XCTAssertEqual(toggles, 2)

        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        XCTAssertEqual(intro.presentations.last?.screen, .playback)
        XCTAssertNil(intro.recordingActions, "Later steps have no recording buttons")

        XCTAssertTrue(logs.contains { $0.contains("click fallback toggled recording screen=recording") })
        XCTAssertTrue(logs.contains { $0.contains("recording gate waitingForStart -> waitingForSpeech") })
        XCTAssertTrue(logs.contains { $0.contains("recording gate waitingForSend -> waitingForResponse") })
    }

    func testRecordingStartStopsDiagnosticsAndClearsHelp() {
        let clock = FakeClock()
        let intro = RecordingIntroPresenter()
        let controller = makeController(intro: intro, probe: { Probe() }, clock: clock)
        resume(at: .tutorialRecording)
        controller.showIfNeeded()
        clock.advance(OnboardingTutorialRecordingWatch.silenceGrace)
        controller.checkTutorialRecording()
        XCTAssertEqual(intro.presentations.last?.recordingHelp?.reason, .keyMonitoringUnverified)

        controller.noteTutorialRecordingStarted()
        XCTAssertEqual(intro.presentations.last?.screen, .recordingActive)
        XCTAssertNil(intro.presentations.last?.recordingHelp)

        clock.advance(60)
        controller.checkTutorialRecording()
        XCTAssertEqual(intro.presentations.map(\.screen), [.recording, .recording, .recordingActive])
    }

    func testDiagnosticsStayOffWithoutProbe() {
        let clock = FakeClock()
        let intro = RecordingIntroPresenter()
        let controller = makeController(intro: intro, clock: clock)
        resume(at: .tutorialRecording)
        controller.showIfNeeded()
        clock.advance(60)
        controller.checkTutorialRecording()
        XCTAssertEqual(intro.presentations.map(\.screen), [.recording])
    }

    // MARK: - Gesture monitor

    func testGestureCountsCapsLockKeyEventsAndLogsMonitorInstall() {
        var local: ((NSEvent) -> NSEvent?)?
        var logs: [String] = []
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in nil },
            localMonitorInstaller: { _, handler in local = handler; return NSObject() },
            monitorRemover: { _ in },
            diagnosticLogger: { logs.append($0) }
        )

        _ = local?(flagsChanged(keyCode: CapsLockGesture.capsLockKeyCode, flags: [.capsLock]))
        _ = local?(flagsChanged(keyCode: 58, flags: [.option]))
        _ = local?(flagsChanged(keyCode: CapsLockGesture.capsLockKeyCode, flags: []))

        XCTAssertEqual(gesture.capsLockKeyEventCount, 2)
        XCTAssertTrue(logs.contains { $0.contains("armed key=caps-lock monitors=1 global=false") })
        XCTAssertTrue(logs.contains { $0.contains("global monitor unavailable") })
        XCTAssertEqual(logs.filter { $0.contains("first Caps Lock key event seen") }.count, 1)
        gesture.stopMonitoring()
    }

    // MARK: - Helpers

    private typealias Probe = OnboardingTutorialRecordingProbe

    /// An interrupted onboarding: the started flag plus the saved step.
    private func resume(at step: OnboardingStepID) {
        try? Data().write(to: directory.appendingPathComponent(".onboarding-started"))
        OnboardingResumeState.save(step: step, provider: .claude, parentPermissionsReviewed: true)
    }

    private func makeController(
        intro: RecordingIntroPresenter,
        speechReadiness: @escaping () -> SetupRuntimeReadiness = { .ready },
        probe: (() -> OnboardingTutorialRecordingProbe)? = nil,
        toggleRecording: @escaping () -> Void = {},
        retrySpeech: @escaping () -> Void = {},
        clock: FakeClock = FakeClock(),
        checkInterval: TimeInterval = 3_600,
        openSettings: @escaping (URL) -> Void = { _ in },
        onOpenExternalWindow: @escaping () -> Void = {},
        log: @escaping (String) -> Void = { _ in }
    ) -> OnboardingController {
        OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: OnboardingFlagURLs(
                onboarded: directory.appendingPathComponent(".onboarded"),
                architectureVersion: directory.appendingPathComponent(".onboarding-architecture-version"),
                started: directory.appendingPathComponent(".onboarding-started"),
                sessionRun: directory.appendingPathComponent(".session-run"),
                agentChoice: directory.appendingPathComponent(".agent-choice-v1"),
                manualRedo: directory.appendingPathComponent(".onboarding-manual-redo")
            ),
            setWorkingDirectory: { _ in },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeSetupInstaller: { InstalledRuntime() },
            isAgentAuthenticated: { _ in true },
            onOpenExternalWindow: onOpenExternalWindow,
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            loginPromptDwell: 0,
            reduceMotion: { true },
            scheduleWorkspaceOpenAfterTutorialDismissal: { $0() },
            tutorialSpeechReadiness: speechReadiness,
            tutorialRecordingProbe: probe,
            toggleTutorialRecording: toggleRecording,
            retryTutorialSpeechSetup: retrySpeech,
            openTutorialSettings: openSettings,
            tutorialRecordingCheckInterval: checkInterval,
            now: { clock.now },
            diagnosticLog: log
        )
    }

    private func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
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

    private func waitForMainQueue(after delay: TimeInterval) {
        let expectation = XCTestExpectation(description: "Wait for main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { expectation.fulfill() }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: delay + 1), .completed)
    }
}

private final class FakeClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 10_000)

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class InstalledRuntime: OnboardingRuntimeInstalling {
    var status: RelaySetupInstaller.Status = .succeeded
    func install(for provider: GeneralConfig.AgentProvider?) {}
}

private final class RecordingIntroPresenter: OnboardingIntroPresenting {
    private(set) var presentations: [OnboardingTutorialPresentation] = []
    private(set) var recordingActions: OnboardingTutorialRecordingActions?
    private(set) var retryAction: (() -> Void)?

    func present(completion: @escaping () -> Void) {}
    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {}
    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void) {}
    func presentRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                              retryAction: @escaping () -> Void) {}
    func presentAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                                 fullyRendered: @escaping () -> Void,
                                 signInAction: @escaping () -> Void) {}
    func presentAgentLoginTerminal(_ login: any ProviderLoginRunning,
                                   cancelAction: @escaping () -> Void) {}
    func presentWorkspacePrompt(currentPath: String,
                                continueAction: @escaping () -> Void,
                                browseAction: @escaping () -> Void) {}

    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void) {
        presentTutorial(presentation, retryAction: retryAction, recordingActions: nil)
    }

    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void,
                         recordingActions: OnboardingTutorialRecordingActions?) {
        presentations.append(presentation)
        self.retryAction = retryAction
        self.recordingActions = recordingActions
    }

    private(set) var dismissals = 0

    func dismiss(completion: @escaping () -> Void) {
        dismissals += 1
        completion()
    }
}
