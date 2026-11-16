import AppKit
import CoreAudio
import FluidAudio
import XCTest
@testable import relay_runner

/// RR-517: on a managed Mac, Caps Lock did nothing in the tutorial after the
/// app copied itself from the DMG to /Applications and relaunched. Everything
/// here runs with fakes: permission preflight answers, resume state, monitor
/// installers, the Caps Lock state reader and the relocation relaunch.
final class OnboardingManagedMacTests: XCTestCase {
    private var directory: URL!
    private var flagURLs: OnboardingFlagURLs!
    private var engines: [STTEngine] = []

    override func setUpWithError() throws {
        OnboardingResumeState.clear()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        flagURLs = OnboardingFlagURLs(
            onboarded: directory.appendingPathComponent(".onboarded"),
            architectureVersion: directory.appendingPathComponent(".onboarding-architecture-version"),
            started: directory.appendingPathComponent(".onboarding-started"),
            sessionRun: directory.appendingPathComponent(".session-run"),
            agentChoice: directory.appendingPathComponent(".agent-choice-v1"),
            manualRedo: directory.appendingPathComponent(".onboarding-manual-redo")
        )
    }

    override func tearDown() {
        engines.forEach { $0.stop() }
        engines = []
        OnboardingResumeState.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Resume after the DMG-to-/Applications relaunch

    func testResumeAtRecordingAfterRelocationRelaunchStartsSpeechAndCapsLockGesture() throws {
        // The DMG instance only runs the installer: no AppState, no onboarding.
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        XCTAssertNotNil(RelayInstallerContext.current(
            bundleURL: URL(fileURLWithPath: "/Volumes/Relay Runner/Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))
        // The relaunched /Applications copy is the real app.
        XCTAssertNil(RelayInstallerContext.current(
            bundleURL: applications.appendingPathComponent("Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))

        // An onboarding interrupted at the recording step, then relaunched.
        try Data().write(to: flagURLs.started)
        OnboardingResumeState.save(step: .tutorialRecording, provider: .claude, parentPermissionsReviewed: true)

        let host = SpeechHost(engines: { self.engines.append($0) })
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            permissionStatus: { _ in .granted }, // preflight "allowed", as in the report
            prepareTutorialSpeech: { host.prepare() },
            speechReadiness: { host.readiness }
        )

        controller.showIfNeeded()

        XCTAssertEqual(host.prepareCount, 1)
        let engine = try XCTUnwrap(host.engine, "the resumed step must start speech")
        XCTAssertTrue(host.monitorMasks.contains { $0.contains(.flagsChanged) },
                      "the Caps Lock gesture must install its key monitor")
        XCTAssertTrue(host.logs.contains { $0.contains("[CapsLockGesture] armed key=caps-lock") })

        wait(until: { host.logs.contains { $0.contains("Activation key loop started") } })
        wait(until: { intro.tutorialScreens.last == .recording })
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)

        // Caps Lock with no Accessibility and no global monitor still records.
        host.capsLockOn = true
        wait(until: { engine.recordingStartedSerial == 1 })
    }

    func testTutorialSpeechStartCoversEveryEngineState() {
        typealias Start = AppState.TutorialSpeechStart
        XCTAssertEqual(AppState.tutorialSpeechStart(engineExists: false, engineFailed: false, microphone: .granted), Start.start)
        XCTAssertEqual(AppState.tutorialSpeechStart(engineExists: true, engineFailed: true, microphone: .granted), Start.restartFailed)
        XCTAssertEqual(AppState.tutorialSpeechStart(engineExists: true, engineFailed: false, microphone: .granted), Start.running)
        XCTAssertEqual(AppState.tutorialSpeechStart(engineExists: false, engineFailed: false, microphone: .denied), Start.waitForMicrophone)
    }

    func testResumedRecordingStepWaitsForSpeechBeforeAskingForCapsLock() throws {
        try Data().write(to: flagURLs.started)
        OnboardingResumeState.save(step: .tutorialRecording, provider: .codex, parentPermissionsReviewed: true)
        var readiness = SetupRuntimeReadiness.preparing("Loading Phonon 2")
        var logs: [String] = []
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            speechReadiness: { readiness },
            log: { logs.append($0) }
        )

        controller.showIfNeeded()
        XCTAssertEqual(intro.tutorialScreens, [.intro])
        XCTAssertEqual(intro.tutorialMessages.last ?? nil, OnboardingController.tutorialSpeechPreparingMessage)
        XCTAssertTrue(logs.contains { $0.contains("resumed recording step waits for speech") })

        readiness = .ready
        wait(until: { intro.tutorialScreens.last == .recording })
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)
    }

    func testStaleResumeStepFromAnEarlierInstallDoesNotSkipSetup() {
        // App files were reset (no started flag) but UserDefaults kept the step.
        OnboardingResumeState.save(step: .tutorialRecording, provider: .claude, parentPermissionsReviewed: true)
        var prepared = 0
        let intro = PresenterSpy()
        let controller = makeController(intro: intro, prepareTutorialSpeech: {
            prepared += 1
            return true
        })

        controller.showIfNeeded()

        XCTAssertTrue(intro.tutorialScreens.isEmpty, "a fresh install must not open at Caps Lock")
        XCTAssertEqual(intro.agentChoicePrompts, 1)
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(OnboardingResumeState.load()?.step, .agentChoice)
    }

    // MARK: - Preflight "allowed" but no key event

    func testPreflightAllowedWithoutAnyKeyEventIsNotTreatedAsWorking() throws {
        try Data().write(to: flagURLs.started)
        OnboardingResumeState.save(step: .tutorialRecording, provider: .claude, parentPermissionsReviewed: true)
        let clock = Clock()
        var probe = OnboardingTutorialRecordingProbe()
        probe.keyboardAccess = .granted // preflight says allowed
        probe.capsLockKeyEvents = 0     // but no event ever arrives
        var opened: [URL] = []
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            probe: { probe },
            clock: clock,
            openSettings: { opened.append($0) }
        )
        controller.showIfNeeded()
        XCTAssertNil(intro.tutorialHelp.last ?? nil)

        clock.now = clock.now.addingTimeInterval(OnboardingTutorialRecordingWatch.silenceGrace)
        controller.checkTutorialRecording()

        let help = try XCTUnwrap(intro.tutorialHelp.last ?? nil)
        XCTAssertEqual(help.symptom, .noCapsLockEvents)
        XCTAssertEqual(help.reason, .keyMonitoringUnverified)
        XCTAssertEqual(help.fix, .openSettings(.inputMonitoring))
        XCTAssertTrue(help.message.contains("Input Monitoring"))
        XCTAssertFalse(help.message.contains("Accessibility"))

        intro.recordingActions?.fix?()
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"])
    }

    func testCapsLockHelpNeverBlamesAccessibility() {
        var probe = OnboardingTutorialRecordingProbe()
        probe.keyboardAccess = .denied
        // Caps Lock was seen, so access isn't the cause of a silent recording.
        XCTAssertEqual(OnboardingTutorialRecordingHelp.diagnose(.pressedWithoutRecording, probe: probe).reason,
                       .recordingDidNotStart)
        let unseen = OnboardingTutorialRecordingHelp.diagnose(.noCapsLockEvents, probe: probe)
        XCTAssertEqual(unseen.reason, .keyboardAccessMissing)
        XCTAssertEqual(unseen.fix, .openSettings(.inputMonitoring))
        XCTAssertFalse(unseen.message.contains("Accessibility"))
    }

    func testCapsLockRecordsWithoutAccessibilityOrAnyKeyMonitor() {
        var capsLockOn = false
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in nil }, // no Accessibility / Input Monitoring
            localMonitorInstaller: { _, _ in nil },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in },
            capsLockState: { capsLockOn }
        )
        defer { gesture.stopMonitoring() }

        XCTAssertNil(gesture.poll(currentSegment: ""))
        capsLockOn = true
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        capsLockOn = false
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    // MARK: - Managed Accessibility

    func testAccessibilityThatCannotBeGrantedExplainsManagedMacAndLetsUserContinue() {
        let statuses: [PermissionKind: PermissionStatus] = [
            .microphone: .granted, .accessibility: .denied, .screenRecording: .granted,
        ]
        var requests: [PermissionKind] = []
        var copied: [String] = []
        var logs: [String] = []
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            permissionStatus: { statuses[$0] ?? .granted },
            requestPermissionSetup: { permission, _, _ in requests.append(permission) },
            log: { logs.append($0) },
            copyToPasteboard: { copied.append($0) }
        )

        controller.showIfNeeded()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.accessibility])
        XCTAssertNil(intro.permissionPrompts.last?.managedNotice, "the first ask is the normal one")
        XCTAssertNil(intro.managedActions)

        // The user looks in Settings, can't find the row, and comes back.
        intro.permissionAction?()
        XCTAssertEqual(requests, [.accessibility])
        NotificationCenter.default.post(
            name: .relayPermissionSetupEndedWithoutGrant,
            object: PermissionSetupLifecycleEvent(permission: .accessibility, source: .onboarding)
        )
        wait(until: { intro.permissionPrompts.count == 2 })

        let managed = intro.permissionPrompts[1]
        XCTAssertEqual(managed.permission, .accessibility)
        let notice = managed.managedNotice ?? ""
        XCTAssertTrue(notice.contains("your organisation manages this setting"))
        XCTAssertTrue(notice.contains("Ask IT"))
        XCTAssertTrue(notice.contains("Caps Lock and voice work without it"))
        XCTAssertEqual(managed.continueTitle, "Continue without Accessibility")
        XCTAssertNotNil(intro.managedActions)

        intro.managedActions?.copyITRequest()
        XCTAssertEqual(copied.count, 1)
        let request = copied[0]
        XCTAssertTrue(request.contains("Bundle ID: com.relayrunner.app"))
        XCTAssertTrue(request.contains("QK9K4AQRNH"))
        XCTAssertTrue(request.contains("identifier \"com.relayrunner.app\" and anchor apple generic"))
        for service in ["Accessibility", "PostEvent", "ListenEvent", "ScreenCapture"] {
            XCTAssertTrue(request.contains("- \(service) "), service)
        }
        XCTAssertTrue(intro.permissionPrompts.last?.managedNotice?.contains("IT request copied") == true)

        intro.managedActions?.continueWithout()
        XCTAssertEqual(intro.agentChoicePrompts, 1, "onboarding moves on without Accessibility")
        XCTAssertEqual(requests, [.accessibility])
        XCTAssertTrue(logs.contains { $0.contains("continued without permission=accessibility") })
    }

    func testMicrophoneNeverOffersContinueWithout() {
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            permissionStatus: { $0 == .microphone ? .denied : .granted }
        )
        controller.showIfNeeded()
        intro.permissionAction?()
        NotificationCenter.default.post(
            name: .relayPermissionSetupEndedWithoutGrant,
            object: PermissionSetupLifecycleEvent(permission: .microphone, source: .onboarding)
        )
        wait(until: { intro.permissionPrompts.count == 2 })
        XCTAssertNil(intro.permissionPrompts.last?.managedNotice)
        XCTAssertNil(intro.managedActions)
    }

    func testManagedNoticeNamesTheRenamedMacOS27Pane() {
        XCTAssertEqual(PermissionKind.accessibility.settingsPaneName(macOSMajorVersion: 27),
                       "Device Control and Data Access")
        XCTAssertEqual(PermissionKind.accessibility.settingsPaneName(macOSMajorVersion: 15), "Accessibility")
        XCTAssertEqual(PermissionKind.inputMonitoring.settingsPaneName(macOSMajorVersion: 27), "Input Monitoring")
        XCTAssertTrue(OnboardingPermissionTreatment.managedNotice(
            for: .accessibility, itRequestCopied: false, macOSMajorVersion: 27
        ).contains("Privacy & Security > Device Control and Data Access"))
        XCTAssertTrue(OnboardingPermissionTreatment.managedNotice(
            for: .accessibility, itRequestCopied: false, macOSMajorVersion: 15
        ).contains("Privacy & Security > Accessibility"))
    }

    // MARK: - System Settings links

    func testSettingsLinksUseAnchorsTheMacOS27PrivacyPaneDeclares() throws {
        XCTAssertEqual(PermissionKind.accessibility.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionKind.inputMonitoring.settingsURL,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(OnboardingTutorialRecordingHelp.SettingsPane.accessibility.url.absoluteString,
                       PermissionKind.accessibility.settingsURL)
        XCTAssertEqual(OnboardingTutorialRecordingHelp.SettingsPane.inputMonitoring.url.absoluteString,
                       PermissionKind.inputMonitoring.settingsURL)

        // On a macOS 27+ host, check the installed Privacy pane still routes
        // the legacy id and reveals both anchors, without opening Settings.
        let appex = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents")
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              let info = NSDictionary(contentsOf: appex.appendingPathComponent("Info.plist")) else {
            throw XCTSkip("Needs the macOS 27 Privacy & Security extension")
        }
        let attributes = (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"] as? [String: Any]
        XCTAssertEqual(attributes?["legacyBundleIdentifier"] as? String, "com.apple.preference.security")
        XCTAssertEqual(attributes?["allowsXAppleSystemPreferencesURLScheme"] as? Bool, true)
        let services = NSArray(contentsOf: appex.appendingPathComponent("Resources/TCCServiceList.plist")) as? [[String: Any]]
        XCTAssertTrue(services?.contains { $0["revealElementKeyName"] as? String == "Privacy_ListenEvent" } == true)
        let binary = try Data(contentsOf: appex.appendingPathComponent("MacOS/SecurityPrivacyExtension"))
        XCTAssertNotNil(binary.range(of: Data("Privacy_Accessibility".utf8)))
    }

    // MARK: - Unified log diagnostics

    func testSpeechStartAndFailureDiagnosticsGoToTheInjectedLogger() async throws {
        let logs = LogSink()
        let backend = Backend()
        let engine = makeEngine(logs: logs, backend: backend)
        engine.setCaptureAllowed(true)
        try await engine.start()
        try await waitAsync { logs.lines.contains { $0.contains("Activation key loop started") } }
        XCTAssertTrue(logs.lines.contains { $0.contains("[STTEngine] Loading model: phonon-2") })
        XCTAssertTrue(logs.lines.contains { $0.contains("[STTEngine] Model loaded.") })
        XCTAssertTrue(logs.lines.contains { $0.contains("[STTEngine] Audio capture started.") })
        engine.stop()

        let failedLogs = LogSink()
        let failing = makeEngine(logs: failedLogs, backend: Backend(), loadError: TestError.offline)
        do {
            try await failing.start()
            XCTFail("start should throw")
        } catch {}
        XCTAssertTrue(failedLogs.lines.contains { $0.contains("[STTEngine] Start failed: model load error=offline") })

        let captureLogs = LogSink()
        let brokenMic = Backend()
        brokenMic.fails = true
        let noMic = makeEngine(logs: captureLogs, backend: brokenMic)
        noMic.setCaptureAllowed(true)
        do {
            try await noMic.start()
            XCTFail("start should throw")
        } catch {}
        XCTAssertTrue(captureLogs.lines.contains { $0.contains("[STTEngine] Start failed: microphone capture error=") })
    }

    func testGestureDiagnosticsAreKeyFree() {
        var local: ((NSEvent) -> NSEvent?)?
        var logs: [String] = []
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in nil },
            localMonitorInstaller: { _, handler in local = handler; return NSObject() },
            monitorRemover: { _ in },
            diagnosticLogger: { logs.append($0) },
            capsLockState: { false }
        )
        let typed = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "hunter2", charactersIgnoringModifiers: "hunter2",
            isARepeat: false, keyCode: 4
        )!
        _ = local?(typed)
        _ = local?(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.capsLock], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: CapsLockGesture.capsLockKeyCode
        )!)
        gesture.stopMonitoring()

        XCTAssertTrue(logs.contains { $0.contains("monitor active identity=modifier-local") })
        XCTAssertTrue(logs.contains { $0.contains("first Caps Lock key event seen") })
        XCTAssertTrue(logs.contains { $0.contains("monitors stopped") })
        XCTAssertFalse(logs.contains { $0.contains("hunter2") })
    }

    func testUnifiedLogUsesTheSubsystemTheReportCaptured() {
        // The report's only app line was `[com.relay-runner:STTModelPreparation]`.
        XCTAssertEqual(RelayUnifiedLog.subsystem, "com.relay-runner")
    }

    // MARK: - The onboarding Caps Lock deadlock

    func testCapsLockKeyEventAdvancesTutorialResumedAfterRelocation() throws {
        // Onboarding incomplete and resumed at the recording step after the
        // DMG-to-/Applications relaunch.
        try Data().write(to: flagURLs.started)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        OnboardingResumeState.save(step: .tutorialRecording, provider: .claude, parentPermissionsReviewed: true)

        // The Caps Lock state read never sees the key; only the key event arrives.
        let host = SpeechHost(capsLockReaderWorks: false, engines: { self.engines.append($0) })
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            prepareTutorialSpeech: { host.prepare() },
            speechReadiness: { host.readiness }
        )
        controller.showIfNeeded()
        let engine = try XCTUnwrap(host.engine)
        wait(until: { intro.tutorialScreens.last == .recording })
        wait(until: { host.logs.contains { $0.contains("Activation key loop started") } })
        XCTAssertNil(intro.tutorialHelp.last ?? nil, "the monitor is attached, so no waiting state")

        // Caps Lock on, delivered to the running gesture's monitor.
        _ = try XCTUnwrap(host.localHandler)(capsLockEvent(on: true))

        // AppState's poll timer forwards a recording start to the tutorial.
        var observedStarts = 0
        wait(until: {
            if engine.recordingStartedSerial > observedStarts {
                observedStarts = engine.recordingStartedSerial
                controller.noteTutorialRecordingStarted()
            }
            return intro.tutorialScreens.last == .recordingActive
        })
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecordingActive)
        XCTAssertEqual(engine.capsLockKeyEventCount, 1)
    }

    func testCapsLockKeyEventTurnsRecordingOnAndOffWithoutAStateRead() throws {
        var local: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in nil },
            localMonitorInstaller: { _, handler in local = handler; return NSObject() },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in },
            capsLockState: { false }
        )
        defer { gesture.stopMonitoring() }
        let handler = try XCTUnwrap(local)

        XCTAssertNil(gesture.poll(currentSegment: ""))
        _ = handler(capsLockEvent(on: true))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        // Any later modifier event carries Caps Lock's state too.
        _ = handler(modifierEvent(flags: [.capsLock, .shift], keyCode: 56))
        XCTAssertNil(gesture.poll(currentSegment: ""))
        _ = handler(capsLockEvent(on: false))
        XCTAssertNil(gesture.poll(currentSegment: ""))
        XCTAssertFalse(gesture.isActivationHeld)
    }

    func testMissedCapsLockOffEventYieldsToTheStateRead() throws {
        // No global monitor: Caps Lock goes on while Relay is in front, then
        // off in another app, so only the state read sees it go off.
        var capsLockRead = false
        var local: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in nil },
            localMonitorInstaller: { _, handler in local = handler; return NSObject() },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in },
            capsLockState: { capsLockRead }
        )
        defer { gesture.stopMonitoring() }
        let handler = try XCTUnwrap(local)

        capsLockRead = true
        _ = handler(capsLockEvent(on: true))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
        capsLockRead = false
        XCTAssertNil(gesture.poll(currentSegment: ""))
        XCTAssertFalse(gesture.isActivationHeld, "the missed off event doesn't leave recording on")

        // reset() doesn't suppress, so the next Caps Lock press records again.
        gesture.reset()
        _ = handler(capsLockEvent(on: true))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
    }

    // MARK: - Existing installs with only Accessibility

    func testAccessibilityOnlyUpgraderKeepsWorkspaceHotkeysAndKeyMonitoring() {
        // Before RR-517 setup never asked for Input Monitoring.
        let upgrader: [PermissionKind: PermissionStatus] = [
            .microphone: .granted, .accessibility: .granted, .inputMonitoring: .notDetermined,
        ]
        let keyMonitoring = PermissionKind.keyMonitoringStatus { upgrader[$0] ?? .notDetermined }
        XCTAssertEqual(keyMonitoring, .granted)
        // An Accessibility grant arriving later restarts STT and installs Esc too.
        XCTAssertTrue(PermissionKind.keyMonitoringGrants.contains(.accessibility))
        XCTAssertTrue(PermissionKind.keyMonitoringGrants.contains(.inputMonitoring))

        var probe = OnboardingTutorialRecordingProbe()
        probe.keyboardAccess = keyMonitoring
        XCTAssertNotEqual(OnboardingTutorialRecordingHelp.diagnose(.noCapsLockEvents, probe: probe).reason,
                          .keyboardAccessMissing)

        let board = ProgramBoardOverlayController(boardRouteResolver: { .unavailable })
        board.installKeyMonitors(keyMonitoring: keyMonitoring)
        XCTAssertTrue(board.hasLocalKeyMonitor)
        XCTAssertTrue(board.hasGlobalKeyMonitor)
    }

    func testWorkspaceInAppShortcutsInstallWithoutAnyKeyGrant() {
        // Esc and Command-T/W in front of Relay need no permission at all.
        let board = ProgramBoardOverlayController(boardRouteResolver: { .unavailable })
        board.installKeyMonitors(keyMonitoring: .notDetermined)
        XCTAssertTrue(board.hasLocalKeyMonitor)
        XCTAssertFalse(board.hasGlobalKeyMonitor)
    }

    // MARK: - A key monitor that attaches late

    func testLateKeyMonitorShowsWaitingStateThenAdvancesWithoutWorkspaceToggle() throws {
        try Data().write(to: flagURLs.started)
        OnboardingResumeState.save(step: .tutorialRecording, provider: .claude, parentPermissionsReviewed: true)
        // The global monitor install fails three times, then succeeds.
        let host = SpeechHost(globalMonitorFailures: 3, engines: { self.engines.append($0) })
        var opened: [URL] = []
        var workspaceOpens = 0
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            prepareTutorialSpeech: { host.prepare() },
            speechReadiness: { host.readiness },
            openSettings: { opened.append($0) },
            keyMonitorAttached: { host.engine?.isGlobalKeyMonitorAttached ?? false },
            openWorkspace: { workspaceOpens += 1 }
        )

        controller.showIfNeeded()
        let engine = try XCTUnwrap(host.engine)
        let gesture = try XCTUnwrap(host.gesture)
        wait(until: { intro.tutorialScreens.last == .recording })
        XCTAssertFalse(engine.isGlobalKeyMonitorAttached)

        // Waiting state: the message, Open Settings and the click fallback.
        let waiting = try XCTUnwrap(intro.tutorialHelp.last ?? nil)
        XCTAssertEqual(waiting, OnboardingTutorialRecordingHelp.keyMonitorWaiting)
        XCTAssertEqual(waiting.message, "Waiting for macOS to apply the permission. This can take a minute.")
        let actions = try XCTUnwrap(intro.recordingActions)
        actions.fix?()
        XCTAssertEqual(opened.map(\.absoluteString), [PermissionKind.inputMonitoring.settingsURL])
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)
        // Back from System Settings, the step is still waiting.
        XCTAssertTrue(controller.resumeAgentLoginIfWaiting())
        XCTAssertEqual(intro.tutorialHelp.last ?? nil, OnboardingTutorialRecordingHelp.keyMonitorWaiting)

        // Half a double-tap Shift reaches the window before the monitor attaches.
        let local = try XCTUnwrap(host.localHandler)
        _ = local(modifierEvent(flags: [.shift], keyCode: 56))
        _ = local(modifierEvent(flags: [], keyCode: 56))

        // Retries two and three still fail, so the step keeps waiting.
        gesture.retryMissingGlobalMonitors()
        gesture.retryMissingGlobalMonitors()
        controller.checkTutorialKeyMonitor()
        XCTAssertFalse(engine.isGlobalKeyMonitorAttached)
        XCTAssertEqual(intro.tutorialHelp.last ?? nil, OnboardingTutorialRecordingHelp.keyMonitorWaiting)

        // The fourth install succeeds: the step carries on by itself.
        let screensBefore = intro.tutorialScreens.count
        gesture.retryMissingGlobalMonitors()
        XCTAssertTrue(engine.isGlobalKeyMonitorAttached)
        XCTAssertEqual(host.globalInstallAttempts, 4)
        wait(until: { intro.tutorialScreens.count > screensBefore })
        XCTAssertEqual(intro.tutorialScreens.last, .recording)
        XCTAssertNil(intro.tutorialHelp.last ?? nil)
        XCTAssertTrue(intro.recordingActions != nil, "the click fallback stays")

        // The other half of that Shift tap, now through the global monitor,
        // must not complete a double tap and open the Workspace.
        let global = try XCTUnwrap(host.globalHandler)
        global(modifierEvent(flags: [.shift], keyCode: 56))
        global(modifierEvent(flags: [], keyCode: 56))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(engine.boardToggleRequested)
        XCTAssertEqual(workspaceOpens, 0)
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)
    }

    // MARK: - Input Monitoring

    func testGuidedSetupRequestsInputMonitoringBeforeAccessibilityOnEveryInstall() {
        XCTAssertEqual(PermissionKind.guidedSetupOrder,
                       [.microphone, .inputMonitoring, .accessibility, .screenRecording])
        XCTAssertEqual(PermissionKind.keyMonitoring, .inputMonitoring)

        // Caps Lock and the hotkeys are gated on Input Monitoring, not Accessibility.
        let onlyAccessibility: [PermissionKind: PermissionStatus] = [.accessibility: .granted, .inputMonitoring: .denied]
        let onlyInputMonitoring: [PermissionKind: PermissionStatus] = [.accessibility: .denied, .inputMonitoring: .granted]
        XCTAssertEqual(PermissionKind.keyMonitoringStatus { onlyAccessibility[$0] ?? .denied }, .granted,
                       "an existing Accessibility grant still runs the key monitors")
        XCTAssertEqual(PermissionKind.keyMonitoringStatus { onlyInputMonitoring[$0] ?? .denied }, .granted)
        XCTAssertEqual(PermissionKind.keyMonitoringStatus { _ in .notDetermined }, .notDetermined)

        // A fresh install with nothing granted asks for Input Monitoring second.
        var statuses: [PermissionKind: PermissionStatus] = [.microphone: .granted]
        var requests: [PermissionKind] = []
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            permissionStatus: { statuses[$0] ?? .notDetermined },
            requestPermissionSetup: { permission, _, _ in requests.append(permission) }
        )
        controller.showIfNeeded()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.inputMonitoring])
        intro.permissionAction?()
        XCTAssertEqual(requests, [.inputMonitoring])
        statuses[.inputMonitoring] = .granted
        NotificationCenter.default.post(name: .relayPermissionSetupGrantReady,
                                        object: PermissionKind.inputMonitoring.rawValue)
        wait(until: { intro.permissionPrompts.count == 2 })
        XCTAssertEqual(intro.permissionPrompts.last?.permission, .accessibility)
    }

    func testManagedAccessibilityFallsBackToInputMonitoringAndCapsLockWorksWithItAlone() throws {
        // A managed Mac hides Accessibility; Input Monitoring is still offered.
        var statuses: [PermissionKind: PermissionStatus] = [
            .microphone: .granted, .inputMonitoring: .notDetermined,
            .accessibility: .denied, .screenRecording: .granted,
        ]
        var requests: [PermissionKind] = []
        let intro = PresenterSpy()
        let controller = makeController(
            intro: intro,
            permissionStatus: { statuses[$0] ?? .denied },
            requestPermissionSetup: { permission, _, _ in requests.append(permission) }
        )
        controller.showIfNeeded()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.inputMonitoring])
        intro.permissionAction?()
        statuses[.inputMonitoring] = .granted
        NotificationCenter.default.post(name: .relayPermissionSetupGrantReady,
                                        object: PermissionKind.inputMonitoring.rawValue)
        wait(until: { intro.permissionPrompts.last?.permission == .accessibility })

        intro.permissionAction?()
        NotificationCenter.default.post(
            name: .relayPermissionSetupEndedWithoutGrant,
            object: PermissionSetupLifecycleEvent(permission: .accessibility, source: .onboarding)
        )
        wait(until: { intro.permissionPrompts.last?.managedNotice != nil })
        XCTAssertTrue(intro.permissionPrompts.last?.managedNotice?.contains("Ask IT") == true)
        XCTAssertNotNil(intro.managedActions?.copyITRequest)
        intro.managedActions?.continueWithout()
        XCTAssertEqual(intro.agentChoicePrompts, 1, "onboarding carries on without Accessibility")
        XCTAssertEqual(requests, [.inputMonitoring, .accessibility])

        // The tutorial treats key monitoring as granted on Input Monitoring alone.
        var probe = OnboardingTutorialRecordingProbe()
        probe.keyboardAccess = PermissionKind.keyMonitoringStatus { statuses[$0] ?? .denied }
        XCTAssertEqual(probe.keyboardAccess, .granted)
        XCTAssertNotEqual(OnboardingTutorialRecordingHelp.diagnose(.noCapsLockEvents, probe: probe).reason,
                          .keyboardAccessMissing)

        // With Input Monitoring the global monitor sees Caps Lock in other apps,
        // and that alone starts recording.
        var global: ((NSEvent) -> Void)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, handler in global = handler; return NSObject() },
            localMonitorInstaller: { _, _ in nil },
            monitorRemover: { _ in },
            diagnosticLogger: { _ in },
            capsLockState: { false }
        )
        defer { gesture.stopMonitoring() }
        XCTAssertTrue(gesture.hasGlobalKeyMonitor)
        try XCTUnwrap(global)(capsLockEvent(on: true))
        XCTAssertEqual(gesture.poll(currentSegment: ""), .startRecording)
    }

    func testSetupCopyNoLongerSaysAccessibilityCoversHotkeys() {
        let accessibility = OnboardingPermissionTreatment.explanation(for: .accessibility)
        XCTAssertTrue(accessibility.contains("Voice, Caps Lock and the hotkeys don't need it"))
        XCTAssertTrue(OnboardingPermissionTreatment.explanation(for: .inputMonitoring).contains("Caps Lock"))
        XCTAssertTrue(OnboardingPermissionTreatment.managedNotice(for: .inputMonitoring, itRequestCopied: false)
            .contains("Caps Lock and the hotkeys need it"))
        XCTAssertTrue(ManagedPermissionRequest.text().contains("Input Monitoring lets Caps Lock and the hotkeys work"))
    }

    private func capsLockEvent(on: Bool) -> NSEvent {
        modifierEvent(flags: on ? [.capsLock] : [], keyCode: CapsLockGesture.capsLockKeyCode)
    }

    private func modifierEvent(flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: - Helpers

    private func makeController(
        intro: PresenterSpy,
        permissionStatus: @escaping (PermissionKind) -> PermissionStatus = { _ in .granted },
        requestPermissionSetup: @escaping (PermissionKind, PermissionSetupSource, String) -> Void = { _, _, _ in },
        prepareTutorialSpeech: @escaping () -> Bool = { true },
        speechReadiness: @escaping () -> SetupRuntimeReadiness = { .ready },
        probe: (() -> OnboardingTutorialRecordingProbe)? = nil,
        clock: Clock = Clock(),
        openSettings: @escaping (URL) -> Void = { _ in },
        log: @escaping (String) -> Void = { _ in },
        copyToPasteboard: @escaping (String) -> Void = { _ in },
        keyMonitorAttached: @escaping () -> Bool = { true },
        openWorkspace: @escaping () -> Void = {}
    ) -> OnboardingController {
        OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            requestPermissionSetup: requestPermissionSetup,
            permissionStatus: permissionStatus,
            permissionLikelyRestricted: { _ in false },
            makeIntroController: { intro },
            makeSetupInstaller: { Runtime() },
            runtimeAlreadyInstalled: { _ in true },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            loginPromptDwell: 0,
            reduceMotion: { true },
            prepareTutorialSpeech: prepareTutorialSpeech,
            scheduleWorkspaceOpenAfterTutorialDismissal: { $0() },
            openWorkspaceAfterCompletion: openWorkspace,
            tutorialSpeechReadiness: speechReadiness,
            tutorialRecordingProbe: probe,
            tutorialKeyMonitorAttached: keyMonitorAttached,
            openTutorialSettings: openSettings,
            tutorialRecordingCheckInterval: probe == nil ? 0.01 : 3_600,
            now: { clock.now },
            diagnosticLog: log,
            copyToPasteboard: copyToPasteboard
        )
    }

    private func makeEngine(logs: LogSink, backend: Backend, loadError: Error? = nil) -> STTEngine {
        var config = SttConfig()
        config.model = "phonon-2"
        let engine = STTEngine(config: config, dependencies: STTEngineDependencies(
            loadModel: { _, _ in
                if let loadError { throw loadError }
                return AsrManager()
            },
            transcribe: { _, _ in "" },
            makeCapture: { sampleHandler, isRecording in
                AudioCaptureLifecycle(
                    backend: backend,
                    routeMonitor: RouteMonitor(),
                    recoveryDelay: 60,
                    sampleHandler: sampleHandler,
                    isRecording: isRecording
                )
            },
            makeGesture: { key in
                CapsLockGesture(
                    activationKey: key,
                    globalMonitorInstaller: { _, _ in nil },
                    localMonitorInstaller: { _, _ in nil },
                    monitorRemover: { _ in },
                    diagnosticLogger: { logs.append($0) },
                    capsLockState: { false }
                )
            },
            prepareVoiceOutput: {},
            writeVoiceOutput: { _ in true },
            log: { logs.append($0) }
        ))
        engines.append(engine)
        return engine
    }

    private func wait(until condition: @escaping () -> Bool,
                      timeout: TimeInterval = 5,
                      file: StaticString = #filePath,
                      line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func waitAsync(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private enum TestError: Error, CustomStringConvertible {
        case offline
        var description: String { "offline" }
    }
}

/// Stands in for AppState's tutorial speech start: the same plan, a real
/// STTEngine and gesture, fake monitors, microphone and Caps Lock state.
private final class SpeechHost: @unchecked Sendable {
    private let lock = NSLock()
    private var _logs: [String] = []
    private var _capsLockOn = false
    private(set) var engine: STTEngine?
    private(set) var gesture: CapsLockGesture?
    private(set) var prepareCount = 0
    private(set) var monitorMasks: [NSEvent.EventTypeMask] = []
    /// The handler macOS would call for events sent to Relay Runner's windows.
    private(set) var localHandler: ((NSEvent) -> NSEvent?)?
    /// The handler macOS would call for events sent to other apps.
    private(set) var globalHandler: ((NSEvent) -> Void)?
    private(set) var globalInstallAttempts = 0
    private var _started = false
    private let engines: (STTEngine) -> Void
    private let backend = Backend()
    /// False stands in for a Caps Lock state read that never sees the key.
    private let capsLockReaderWorks: Bool
    /// Global monitor installs that fail before one succeeds; nil never succeeds.
    private let globalMonitorFailures: Int?

    init(capsLockReaderWorks: Bool = true,
         globalMonitorFailures: Int? = nil,
         engines: @escaping (STTEngine) -> Void) {
        self.capsLockReaderWorks = capsLockReaderWorks
        self.globalMonitorFailures = globalMonitorFailures
        self.engines = engines
    }

    private func installGlobal(_ handler: @escaping (NSEvent) -> Void) -> Any? {
        globalInstallAttempts += 1
        guard let failures = globalMonitorFailures, globalInstallAttempts > failures else { return nil }
        globalHandler = handler
        return NSObject()
    }

    var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
    var capsLockOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _capsLockOn }
        set { lock.lock(); _capsLockOn = newValue; lock.unlock() }
    }
    var readiness: SetupRuntimeReadiness {
        lock.lock(); defer { lock.unlock() }
        return _started ? .ready : .preparing("Loading Phonon 2")
    }

    private func markStarted() {
        lock.lock(); _started = true; lock.unlock()
    }

    private func log(_ line: String) {
        lock.lock(); _logs.append(line); lock.unlock()
    }

    func prepare() -> Bool {
        prepareCount += 1
        switch AppState.tutorialSpeechStart(engineExists: engine != nil, engineFailed: false, microphone: .granted) {
        case .start, .restartFailed:
            let engine = STTEngine(config: SttConfig(), dependencies: STTEngineDependencies(
                loadModel: { _, _ in AsrManager() },
                transcribe: { _, _ in "" },
                makeCapture: { [backend] sampleHandler, isRecording in
                    AudioCaptureLifecycle(backend: backend, routeMonitor: RouteMonitor(), recoveryDelay: 60,
                                          sampleHandler: sampleHandler, isRecording: isRecording)
                },
                makeGesture: { [weak self] key in
                    let gesture = CapsLockGesture(
                        activationKey: key,
                        globalMonitorInstaller: { _, handler in self?.installGlobal(handler) },
                        localMonitorInstaller: { mask, handler in
                            self?.monitorMasks.append(mask)
                            self?.localHandler = handler
                            return NSObject()
                        },
                        monitorRemover: { _ in },
                        diagnosticLogger: { self?.log($0) },
                        capsLockState: { [weak self] in
                            guard let self, self.capsLockReaderWorks else { return false }
                            return self.capsLockOn
                        }
                    )
                    self?.gesture = gesture
                    return gesture
                },
                prepareVoiceOutput: {},
                writeVoiceOutput: { _ in true },
                log: { [weak self] in self?.log($0) }
            ))
            engine.tutorialActive = true
            self.engine = engine
            engines(engine)
            // AppState.syncCommandCaptureOwnership with the tutorial active.
            engine.setCaptureAllowed(AppState.commandCaptureAllowed(
                hasActiveSession: false,
                sessionControlsTutorialActive: true,
                noteOwnsForeground: false
            ))
            Task { [weak self] in
                try await engine.start()
                self?.markStarted()
            }
        case .running, .waitForMicrophone:
            break
        }
        return true
    }
}

private final class Clock {
    var now = Date(timeIntervalSinceReferenceDate: 50_000)
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func append(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
}

private final class Backend: AudioCaptureBackend {
    var onConfigurationChange: ((String) -> Void)?
    var fails = false

    func start(sampleHandler: @escaping ([Float]) -> Void) throws -> AudioInputRoute {
        if fails { throw NSError(domain: "RR517.mic", code: 1) }
        return AudioInputRoute(deviceID: 1, sampleRate: 48_000, channelCount: 1)
    }

    func stop() {}
}

private final class RouteMonitor: DefaultAudioInputMonitoring {
    var onDefaultInputChanged: ((AudioObjectID?) -> Void)?
    func start() throws {}
    func stop() {}
}

private final class Runtime: OnboardingRuntimeInstalling {
    var status: RelaySetupInstaller.Status = .succeeded
    func install(for provider: GeneralConfig.AgentProvider?) {}
}

private final class PresenterSpy: OnboardingIntroPresenting {
    private(set) var permissionPrompts: [OnboardingPermissionPromptPresentation] = []
    private(set) var permissionAction: (() -> Void)?
    private(set) var managedActions: OnboardingPermissionManagedActions?
    private(set) var agentChoicePrompts = 0
    private(set) var tutorialScreens: [OnboardingTutorialScreen] = []
    private(set) var tutorialMessages: [String?] = []
    private(set) var tutorialHelp: [OnboardingTutorialRecordingHelp?] = []
    private(set) var recordingActions: OnboardingTutorialRecordingActions?

    func present(completion: @escaping () -> Void) { completion() }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {
        presentPermissionPrompt(presentation, action: action, skipAction: nil, managedActions: nil)
    }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void,
                                 skipAction: (() -> Void)?,
                                 managedActions: OnboardingPermissionManagedActions?) {
        permissionPrompts.append(presentation)
        permissionAction = action
        self.managedActions = managedActions
    }

    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void) {
        agentChoicePrompts += 1
    }

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
        tutorialScreens.append(presentation.screen)
        tutorialMessages.append(presentation.message)
        tutorialHelp.append(presentation.recordingHelp)
        self.recordingActions = recordingActions
    }

    func dismiss(completion: @escaping () -> Void) { completion() }
}
