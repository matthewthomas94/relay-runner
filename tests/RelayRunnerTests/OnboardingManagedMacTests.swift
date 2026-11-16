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
        copyToPasteboard: @escaping (String) -> Void = { _ in }
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
            tutorialSpeechReadiness: speechReadiness,
            tutorialRecordingProbe: probe,
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
    private(set) var prepareCount = 0
    private(set) var monitorMasks: [NSEvent.EventTypeMask] = []
    private var _started = false
    private let engines: (STTEngine) -> Void
    private let backend = Backend()

    init(engines: @escaping (STTEngine) -> Void) {
        self.engines = engines
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
                    CapsLockGesture(
                        activationKey: key,
                        globalMonitorInstaller: { _, _ in nil }, // no usable Accessibility grant
                        localMonitorInstaller: { mask, _ in self?.monitorMasks.append(mask); return NSObject() },
                        monitorRemover: { _ in },
                        diagnosticLogger: { self?.log($0) },
                        capsLockState: { self?.capsLockOn ?? false }
                    )
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
