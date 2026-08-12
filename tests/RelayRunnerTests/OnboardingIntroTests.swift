import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

final class OnboardingIntroTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OnboardingResumeState.clear()
    }

    override func tearDown() {
        OnboardingResumeState.clear()
        super.tearDown()
    }

    func testIntroEligibilityIsFreshAutomaticOnly() {
        XCTAssertTrue(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: true,
            wasInterrupted: false,
            reduceMotion: false
        ))
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: true,
            reduceMotion: false
        ))
    }

    func testReduceMotionBypassesIntro() {
        XCTAssertFalse(OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: false,
            reduceMotion: true
        ))
    }

    func testPristineAutomaticShowIfNeededPresentsIntroAndWritesStartedSentinel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var notchOverrideStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { false }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(notchOverrideStates, [true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testSharedOnboardingStateLocksOtherInstancesUntilCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)

        XCTAssertFalse(OnboardingController.sharedOnboardingInProgress(flagURLs: flagURLs))

        try Data().write(to: flagURLs.started)
        XCTAssertTrue(OnboardingController.sharedOnboardingInProgress(flagURLs: flagURLs))

        try Data().write(to: flagURLs.onboarded)
        XCTAssertTrue(OnboardingController.sharedOnboardingInProgress(flagURLs: flagURLs))

        try Data(OnboardingController.currentArchitectureVersion.utf8)
            .write(to: flagURLs.architectureVersion)
        XCTAssertFalse(OnboardingController.sharedOnboardingInProgress(flagURLs: flagURLs))

        try Data().write(to: flagURLs.manualRedo)
        XCTAssertTrue(OnboardingController.sharedOnboardingInProgress(flagURLs: flagURLs))
    }

    func testCinematicCompletionShowsFirstPermissionBeforeSettingsHandoff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var notchOverrideStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { false }
        )

        controller.showIfNeeded()
        intro.completeCinematic()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        XCTAssertEqual(notchOverrideStates, [true])
    }

    func testReduceMotionFreshAutomaticUsesStaticIntroPermissionPresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        XCTAssertFalse(presentation.isPresented)
    }

    func testFreshPermissionSequenceRequestsThroughCoordinatorAndHandsOffAfterAllGrants() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.denied) }
        )
        var events: [String] = []
        var notchOverrideStates: [Bool] = []
        intro.onDismiss = { events.append("dismiss") }
        var workingDirectoryWrites: [String] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            setOnboardingNotchOverrideActive: {
                notchOverrideStates.append($0)
                events.append("notch:\($0)")
            },
            requestPermissionSetup: { kind, source, _ in
                events.append("request:\(kind.rawValue):\(source)")
            },
            permissionStatus: { statuses[$0] ?? .denied },
            makeIntroController: { intro },
            pickWorkspaceDirectory: { prepare, completion in
                prepare {
                    events.append("picker")
                    completion("/Users/example/dev")
                }
            },
            reduceMotion: { false }
        )

        controller.showIfNeeded()
        intro.completeCinematic()

        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
        intro.performPermissionAction()
        XCTAssertEqual(Array(events.suffix(1)), ["request:microphone:onboarding"])

        statuses[.microphone] = .granted
        postGrant(.microphone)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone, .accessibility])

        intro.performPermissionAction()
        XCTAssertEqual(Array(events.suffix(2)), ["dismiss", "request:accessibility:onboarding"])
        statuses[.accessibility] = .granted
        postGrant(.accessibility)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [
            .microphone,
            .accessibility,
            .screenRecording,
        ])

        intro.performPermissionAction()
        statuses[.screenRecording] = .granted
        postGrant(.screenRecording)
        drainMainQueue()

        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.codex])
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(workingDirectoryWrites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
    }

    func testAllPermissionsGrantedStartsIntroAgentChoiceWithoutCinematic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var notchOverrideStates: [Bool] = []
        var workingDirectoryWrites: [String] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            setOnboardingNotchOverrideActive: {
                notchOverrideStates.append($0)
            },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            pickWorkspaceDirectory: { prepare, completion in
                prepare {
                    completion(nil)
                }
            },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.codex])
        XCTAssertTrue(workingDirectoryWrites.isEmpty)
        XCTAssertEqual(notchOverrideStates, [true])
    }

    func testSelectingClaudePersistsProviderAndStartsSelectedRuntimeSetup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .failed(message: "Claude command is missing."))
        var providerWrites: [GeneralConfig.AgentProvider] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getAgentProvider: { .codex },
            setAgentProvider: { providerWrites.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in false },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performClaudeAction()

        XCTAssertEqual(providerWrites, [.claude])
        XCTAssertEqual(installer.installProviders, [.claude])
        XCTAssertEqual(intro.runtimePrompts.last?.provider, .claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
    }

    func testRuntimeRetryKeepsSelectedProviderAndUsesFreshInstaller() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let initialInstaller = FakeRuntimeInstaller()
        let failedInstaller = FakeRuntimeInstaller(installStatus: .failed(message: "Missing Claude."))
        let retryInstaller = FakeRuntimeInstaller(installStatus: .failed(message: "Still missing Claude."))
        var installers: [FakeRuntimeInstaller] = [initialInstaller, failedInstaller, retryInstaller]
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installers.removeFirst() },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in false },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performClaudeAction()
        intro.performRuntimeRetry()

        XCTAssertEqual(failedInstaller.installProviders, [.claude])
        XCTAssertEqual(retryInstaller.installProviders, [.claude])
        XCTAssertEqual(intro.runtimePrompts.map(\.provider).suffix(2), [.claude, .claude])
    }

    func testAlreadyAuthenticatedProviderSkipsExternalLoginAndShowsWorkspaceLast() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var terminalLaunches: [GeneralConfig.AgentProvider] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            openAgentLoginInTerminal: {
                terminalLaunches.append($0)
                return true
            },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(terminalLaunches, [])
        XCTAssertEqual(intro.loginPrompts.last?.signedIn, true)
        XCTAssertEqual(intro.workspacePromptPaths, ["/Users/example/current"])
        XCTAssertEqual(intro.events.filter { $0.hasPrefix("workspace") }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testRegistryV2FreshOnboardingSkipsWorkspaceFolderAndAllowsEmptyRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var workspaceWrites: [String] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { workspaceWrites.append($0) },
            usesProjectRegistryV2: true,
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)

        XCTAssertTrue(intro.workspacePromptPaths.isEmpty)
        XCTAssertTrue(workspaceWrites.isEmpty)
        XCTAssertEqual(intro.tutorialPresentations.first?.screen, .intro)
        XCTAssertFalse(intro.tutorialPresentations.map(\.screen).contains(.workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        completeSessionControlsTutorial(controller)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(
            try String(contentsOf: flagURLs.architectureVersion, encoding: .utf8),
            OnboardingController.currentArchitectureVersion
        )
    }

    func testRegistryV2UpgradeForcesOneFullOnboardingPass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        let intro = CapturingIntroPresenter()
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            usesProjectRegistryV2: true,
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in true },
            isAgentAuthenticated: { _ in true },
            introAdvanceDelay: 0,
            reduceMotion: { false }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(intro.events, ["cinematic"])

        intro.completeCinematic()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)

        XCTAssertTrue(intro.workspacePromptPaths.isEmpty)
        XCTAssertEqual(intro.tutorialPresentations.first?.screen, .intro)
        completeSessionControlsTutorial(controller)
        XCTAssertEqual(
            try String(contentsOf: flagURLs.architectureVersion, encoding: .utf8),
            OnboardingController.currentArchitectureVersion
        )

        let secondIntro = CapturingIntroPresenter()
        let secondController = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            usesProjectRegistryV2: true,
            permissionStatus: { _ in .granted },
            makeIntroController: { secondIntro },
            reduceMotion: { true }
        )
        secondController.showIfNeeded()

        XCTAssertEqual(secondIntro.presentCallCount, 0)
        XCTAssertTrue(secondIntro.permissionPrompts.isEmpty)
        XCTAssertTrue(secondIntro.agentChoiceSelectedProviders.isEmpty)
    }

    func testLoginDismissesIntroBeforeTerminalAndRestoresRetryOnCancel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var events: [String] = []
        intro.onDismiss = { events.append("dismiss") }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setOnboardingNotchOverrideActive: {
                events.append("notch:\($0)")
            },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in false },
            openAgentLoginInTerminal: {
                events.append("terminal:\($0.rawValue)")
                return true
            },
            onOpenExternalWindow: {
                events.append("external")
            },
            runtimePollInterval: 0.01,
            authPollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        events.removeAll()

        intro.performLoginAction()

        XCTAssertEqual(events, ["dismiss", "notch:false", "external", "terminal:codex"])

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(events.suffix(1), ["notch:true"])
        XCTAssertEqual(intro.loginPrompts.last?.provider, .codex)
        XCTAssertEqual(intro.loginPrompts.last?.signedIn, false)
        XCTAssertEqual(
            intro.loginPrompts.last?.message,
            "Codex sign-in did not complete. Try again when you are ready."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
    }

    func testLoginSuccessShowsWorkspaceLastAndWorkspaceSelectionCompletesOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var authenticated = false
        var events: [String] = []
        var workingDirectoryWrites: [String] = []
        var workspaceOpenCount = 0
        intro.onDismiss = { events.append("dismiss") }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            setOnboardingNotchOverrideActive: {
                events.append("notch:\($0)")
            },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in authenticated },
            openAgentLoginInTerminal: { _ in
                authenticated = true
                return true
            },
            runtimePollInterval: 0.01,
            authPollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare {
                    events.append("picker")
                    completion("/Users/example/dev")
                }
            },
            reduceMotion: { true },
            openWorkspaceAfterCompletion: {
                events.append("workspaceOpen")
                workspaceOpenCount += 1
            }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        intro.performLoginAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(intro.workspacePromptPaths, [NSHomeDirectory()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        events.removeAll()
        intro.performWorkspaceAction()

        XCTAssertEqual(workingDirectoryWrites, ["/Users/example/dev"])
        XCTAssertEqual(events, ["dismiss", "notch:false", "picker", "notch:true"])
        XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.intro])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        completeSessionControlsTutorial(controller)

        XCTAssertEqual(workspaceOpenCount, 1)
        XCTAssertEqual(
            intro.tutorialPresentations.map(\.screen),
            [.intro, .recording, .recordingActive, .playback, .cancellation, .workspace]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertNil(OnboardingResumeState.load())
    }

    func testTutorialMovesFromRecordingActiveToPlaybackWhileWaitingForResponse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let controller = makeSessionControlsTutorialController(flagURLs: flagURLs, intro: intro)
        beginSessionControlsTutorial(controller, intro: intro, provider: .codex)

        controller.noteTutorialResponseReady("Startup greeting")
        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        controller.noteTutorialResponseReady("")
        controller.noteTutorialResponseReady("   ")
        controller.noteTutorialPlaybackRequested()

        XCTAssertEqual(
            intro.tutorialPresentations.map(\.screen),
            [.intro, .recording, .recordingActive, .playback]
        )
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialPlayback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        controller.noteTutorialResponseReady("Hello, how are you?")
        controller.noteTutorialPlaybackRequested()

        XCTAssertEqual(
            intro.tutorialPresentations.map(\.screen),
            [.intro, .recording, .recordingActive, .playback]
        )
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialPlayback)
    }

    func testTutorialUsesExactLocalReplyAndSingleGestureReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let controller = makeSessionControlsTutorialController(flagURLs: flagURLs, intro: intro)
        beginSessionControlsTutorial(controller, intro: intro, provider: .codex)

        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        XCTAssertEqual(
            controller.noteTutorialRecordingSent(),
            OnboardingSessionControlsTutorial.deterministicReply
        )
        controller.noteTutorialResponseReady("provider response")
        XCTAssertNil(controller.noteTutorialPlaybackRequested())

        controller.noteTutorialResponseReady(OnboardingSessionControlsTutorial.deterministicReply)
        XCTAssertEqual(controller.noteTutorialPlaybackRequested(), .play)
        XCTAssertNil(controller.noteTutorialPlaybackRequested())
        controller.noteTutorialPlaybackStarted()
        XCTAssertEqual(
            controller.noteTutorialPlaybackFinished(),
            OnboardingSessionControlsTutorial.deterministicReply
        )

        XCTAssertEqual(controller.noteTutorialPlaybackRequested(), .replay)
        XCTAssertNil(controller.noteTutorialPlaybackRequested())
        XCTAssertEqual(intro.tutorialPresentations.last?.screen, .cancellation)
    }

    func testTutorialCancellationAcceptsWaitingOrPlayingReplayForBothProviders() throws {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            for playBeforeCancelling in [false, true] {
                OnboardingResumeState.clear()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
                let intro = CapturingIntroPresenter()
                let controller = makeSessionControlsTutorialController(flagURLs: flagURLs, intro: intro)
                beginSessionControlsTutorial(controller, intro: intro, provider: provider)

                controller.noteTutorialRecordingStarted()
                XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.intro, .recording, .recordingActive])
                XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecordingActive)

                controller.noteTutorialSpeechDetected()
                controller.noteTutorialRecordingSent()
                XCTAssertEqual(
                    intro.tutorialPresentations.map(\.screen),
                    [.intro, .recording, .recordingActive, .playback]
                )
                XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialPlayback)

                controller.noteTutorialResponseReady("Hello, how are you?")
                controller.noteTutorialCancelRequested()
                controller.noteTutorialPlaybackRequested()
                controller.noteTutorialCancelRequested()
                controller.noteTutorialPlaybackStarted()
                controller.noteTutorialCancelRequested()

                XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialPlayback)
                XCTAssertEqual(
                    controller.noteTutorialPlaybackFinished(),
                    "Hello, how are you?"
                )
                XCTAssertEqual(
                    intro.tutorialPresentations.map(\.screen),
                    [.intro, .recording, .recordingActive, .playback, .cancellation]
                )
                XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialCancellation)

                if playBeforeCancelling {
                    controller.noteTutorialPlaybackRequested()
                }
                controller.noteTutorialCancelRequested()

                XCTAssertEqual(
                    intro.tutorialPresentations.map(\.screen),
                    [.intro, .recording, .recordingActive, .playback, .cancellation, .workspace]
                )
                XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialWorkspace)
                controller.noteTutorialPlaybackStarted()
                XCTAssertNil(controller.noteTutorialPlaybackFinished())
            }
        }
    }

    func testTutorialRecognizesPlaybackThatStartedBeforeGesturePoll() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let controller = makeSessionControlsTutorialController(flagURLs: flagURLs, intro: intro)
        beginSessionControlsTutorial(controller, intro: intro, provider: .codex)
        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        controller.noteTutorialResponseReady("Hello, how are you?")

        controller.noteTutorialPlaybackRequested(playbackActive: true)
        controller.noteTutorialPlaybackFinished()

        XCTAssertEqual(intro.tutorialPresentations.last?.screen, .cancellation)
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialCancellation)
    }

    func testTutorialResumeTransientSubstepsFallsBackToRecordingWithoutStaleState() throws {
        for step in [
            OnboardingStepID.tutorialRecordingActive,
            .tutorialPlayback,
            .tutorialCancellation,
        ] {
            OnboardingResumeState.clear()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
            OnboardingResumeState.save(
                step: step,
                provider: .codex,
                parentPermissionsReviewed: true
            )
            let intro = CapturingIntroPresenter()
            let controller = makeSessionControlsTutorialController(flagURLs: flagURLs, intro: intro)

            controller.showIfNeeded()

            XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.recording])
            XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)

            controller.noteTutorialPlaybackRequested()
            controller.noteTutorialCancelRequested()

            XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.recording])
            XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        }
    }

    func testTutorialRecordingUsesLocalSpeechPreparationForBothProviders() throws {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            OnboardingResumeState.clear()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
            OnboardingResumeState.save(
                step: .tutorialRecording,
                provider: provider,
                parentPermissionsReviewed: true
            )
            let intro = CapturingIntroPresenter()
            var preparationCount = 0
            let controller = makeSessionControlsTutorialController(
                flagURLs: flagURLs,
                intro: intro,
                prepareTutorialSpeech: {
                    preparationCount += 1
                    return true
                }
            )

            controller.showIfNeeded()

            XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.recording])
            XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialRecording)
            XCTAssertEqual(preparationCount, 1, "provider: \(provider.rawValue)")
        }
    }

    func testTutorialResponseAndGestureGatesAreProviderNeutral() throws {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            OnboardingResumeState.clear()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
            let intro = CapturingIntroPresenter()
            var workspaceOpenCount = 0
            let controller = makeSessionControlsTutorialController(
                flagURLs: flagURLs,
                intro: intro,
                workspaceOpen: { workspaceOpenCount += 1 }
            )

            beginSessionControlsTutorial(controller, intro: intro, provider: provider)
            completeSessionControlsTutorial(controller)

            XCTAssertEqual(
                intro.tutorialPresentations.map(\.screen),
                [.intro, .recording, .recordingActive, .playback, .cancellation, .workspace],
                "provider: \(provider.rawValue)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: flagURLs.onboarded.path),
                "provider: \(provider.rawValue)"
            )
            XCTAssertEqual(workspaceOpenCount, 1, "provider: \(provider.rawValue)")
        }
    }

    func testTutorialWorkspaceToggleCanRetryAfterNoSuccessSignal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var workspaceOpenCount = 0
        let controller = makeSessionControlsTutorialController(
            flagURLs: flagURLs,
            intro: intro,
            workspaceOpen: { workspaceOpenCount += 1 }
        )

        beginSessionControlsTutorial(controller, intro: intro, provider: .codex)
        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        controller.noteTutorialResponseReady("Hello, how are you?")
        controller.noteTutorialPlaybackRequested()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialPlaybackFinished()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialCancelRequested()
        drainMainQueue()

        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        drainMainQueue()

        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(workspaceOpenCount, 0)

        controller.noteTutorialWorkspaceToggled()
        drainMainQueue()

        XCTAssertNil(OnboardingResumeState.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(workspaceOpenCount, 1)
    }

    func testTutorialWorkspaceToggleCompletesExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var workspaceOpenCount = 0
        let controller = makeSessionControlsTutorialController(
            flagURLs: flagURLs,
            intro: intro,
            workspaceOpen: { workspaceOpenCount += 1 }
        )

        beginSessionControlsTutorial(controller, intro: intro, provider: .codex)
        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        controller.noteTutorialResponseReady("Hello, how are you?")
        controller.noteTutorialPlaybackRequested()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialPlaybackFinished()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialCancelRequested()
        controller.noteTutorialWorkspaceToggled()
        controller.noteTutorialWorkspaceToggled()
        drainMainQueue()

        XCTAssertNil(OnboardingResumeState.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(workspaceOpenCount, 1)
    }

    func testTutorialLocalSpeechPreparationFailureShowsRetryWithoutCompletingOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var speechPreparations = [false, true]
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { _ in },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/dev") }
            },
            reduceMotion: { true },
            prepareTutorialSpeech: {
                speechPreparations.removeFirst()
            }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        intro.performWorkspaceAction()

        XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.sessionRetry])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(OnboardingResumeState.load()?.step, .tutorialSessionRetry)

        intro.performRuntimeRetry()
        XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.sessionRetry, .intro])

        completeSessionControlsTutorial(controller)

        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertNil(OnboardingResumeState.load())
    }

    func testWorkspaceSelectionPersistsBeforeCompletionAndOpensWorkspaceAfterUnlock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var events: [String] = []
        var firstRunExperienceStates: [Bool] = []
        intro.onDismiss = { events.append("dismiss") }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { events.append("persist:\($0)") },
            setOnboardingNotchOverrideActive: { events.append("notch:\($0)") },
            setFirstRunExperienceActive: {
                firstRunExperienceStates.append($0)
                events.append("firstRun:\($0)")
            },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare {
                    events.append("picker")
                    completion("/Users/example/dev")
                }
            },
            reduceMotion: { true },
            openWorkspaceAfterCompletion: { events.append("workspaceOpen") }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        events.removeAll()

        intro.performWorkspaceAction()

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "picker",
            "persist:/Users/example/dev",
            "notch:true",
        ])
        XCTAssertEqual(intro.tutorialPresentations.map(\.screen), [.intro])
        XCTAssertEqual(firstRunExperienceStates, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        completeSessionControlsTutorial(controller)

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "picker",
            "persist:/Users/example/dev",
            "notch:true",
            "dismiss",
            "notch:false",
            "firstRun:false",
            "workspaceOpen",
        ])
        XCTAssertEqual(firstRunExperienceStates, [true, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testWorkspaceTutorialDoesNotFinishUntilAllControlEventsSucceed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var events: [String] = []
        intro.onDismiss = { events.append("dismiss") }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { events.append("persist:\($0)") },
            setOnboardingNotchOverrideActive: { events.append("notch:\($0)") },
            setFirstRunExperienceActive: { events.append("firstRun:\($0)") },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/dev") }
            },
            reduceMotion: { false },
            openWorkspaceAfterCompletion: { events.append("workspaceOpen") }
        )

        controller.showIfNeeded()
        intro.completeCinematic()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        events.removeAll()

        intro.performWorkspaceAction()

        XCTAssertEqual(events, ["dismiss", "notch:false", "persist:/Users/example/dev", "notch:true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        waitForMainQueue(after: 0.08)

        XCTAssertEqual(events, ["dismiss", "notch:false", "persist:/Users/example/dev", "notch:true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        completeSessionControlsTutorial(controller)

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "persist:/Users/example/dev",
            "notch:true",
            "dismiss",
            "notch:false",
            "firstRun:false",
            "workspaceOpen",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testWorkspaceTutorialCompletesAfterOrderedControlEventsWhenMotionAllowed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var events: [String] = []
        intro.onDismiss = { events.append("dismiss") }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { events.append("persist:\($0)") },
            setOnboardingNotchOverrideActive: { events.append("notch:\($0)") },
            setFirstRunExperienceActive: { events.append("firstRun:\($0)") },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/dev") }
            },
            reduceMotion: { false },
            openWorkspaceAfterCompletion: { events.append("workspaceOpen") }
        )

        controller.showIfNeeded()
        intro.completeCinematic()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        events.removeAll()

        intro.performWorkspaceAction()

        XCTAssertEqual(events, ["dismiss", "notch:false", "persist:/Users/example/dev", "notch:true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        completeSessionControlsTutorial(controller)

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "persist:/Users/example/dev",
            "notch:true",
            "dismiss",
            "notch:false",
            "firstRun:false",
            "workspaceOpen",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertNil(OnboardingResumeState.load())
    }

    func testWorkspaceTutorialRetainsControllerOwnedPresenterUntilDismissalCompletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        var events: [String] = []
        let presenterFactory = DeferredDismissIntroPresenterFactory { events.append($0) }
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { events.append("persist:\($0)") },
            setOnboardingNotchOverrideActive: { events.append("notch:\($0)") },
            setFirstRunExperienceActive: { events.append("firstRun:\($0)") },
            permissionStatus: { _ in .granted },
            makeIntroController: { presenterFactory.makePresenter() },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/dev") }
            },
            reduceMotion: { true },
            openWorkspaceAfterCompletion: { events.append("workspaceOpen") }
        )

        controller.showIfNeeded()
        XCTAssertNotNil(presenterFactory.presenter)

        presenterFactory.presenter?.performCodexAction()
        waitForMainQueue(after: 0.05)
        events.removeAll()

        presenterFactory.presenter?.performWorkspaceAction()

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "persist:/Users/example/dev",
            "notch:true",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertNotNil(presenterFactory.presenter)
        XCTAssertFalse(events.contains("firstRun:false"))
        XCTAssertFalse(events.contains("workspaceOpen"))

        completeSessionControlsTutorial(controller)

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "persist:/Users/example/dev",
            "notch:true",
            "dismiss",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))

        presenterFactory.presenter?.completeDismissal()
        drainMainQueue()

        XCTAssertEqual(events, [
            "dismiss",
            "notch:false",
            "persist:/Users/example/dev",
            "notch:true",
            "dismiss",
            "notch:false",
            "firstRun:false",
            "workspaceOpen",
            "deinit",
        ])
        XCTAssertNil(presenterFactory.presenter)
    }

    func testWorkspaceCancelRestoresFinalIntroStepWithoutPersisting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var workingDirectoryWrites: [String] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare {
                    completion(nil)
                }
            },
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)
        intro.performWorkspaceAction()

        XCTAssertEqual(intro.workspacePromptPaths, [NSHomeDirectory(), NSHomeDirectory()])
        XCTAssertTrue(workingDirectoryWrites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testWorkspaceContinuePersistsExistingPathWithoutOpeningPicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var workingDirectoryWrites: [String] = []
        var pickerCalls = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { _, _ in pickerCalls += 1 },
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)

        intro.performWorkspaceContinueAction()

        XCTAssertEqual(intro.workspacePromptPaths, ["/Users/example/current"])
        XCTAssertEqual(workingDirectoryWrites, ["/Users/example/current"])
        XCTAssertEqual(pickerCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testWorkspaceContinueUsesHomeFallbackWithoutOpeningPicker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var workingDirectoryWrites: [String] = []
        var pickerCalls = 0
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "" },
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { _, _ in pickerCalls += 1 },
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performCodexAction()
        waitForMainQueue(after: 0.05)

        intro.performWorkspaceContinueAction()

        XCTAssertEqual(intro.workspacePromptPaths, [NSHomeDirectory()])
        XCTAssertEqual(workingDirectoryWrites, [NSHomeDirectory()])
        XCTAssertEqual(pickerCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
    }

    func testInterruptedReadyResumeRestoresWorkspaceWithoutCinematicOrSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.started)
        OnboardingResumeState.save(step: .ready, provider: .claude, parentPermissionsReviewed: true)
        let intro = CapturingIntroPresenter()
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            runtimeAlreadyInstalled: { _ in true },
            isAgentAuthenticated: { _ in true },
            reduceMotion: { false }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertEqual(intro.workspacePromptPaths, [NSHomeDirectory()])
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)
    }

    func testUpgradeMissingAgentChoiceRunsFocusedProviderFlowWithoutWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var notchOverrideStates: [Bool] = []
        var providerWrites: [GeneralConfig.AgentProvider] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setAgentProvider: { providerWrites.append($0) },
            setOnboardingNotchOverrideActive: { notchOverrideStates.append($0) },
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performClaudeAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(providerWrites, [.claude])
        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.codex])
        XCTAssertTrue(intro.workspacePromptPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertEqual(notchOverrideStates, [true, false])
    }

    func testOnboardedUserWithoutSessionRunDoesNotReopenOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        let intro = CapturingIntroPresenter()
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.sessionRun.path))
        XCTAssertTrue(intro.permissionPrompts.isEmpty)
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)
        XCTAssertTrue(intro.workspacePromptPaths.isEmpty)
    }

    func testFreshPermissionDenialReturnsToSameIntroPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.granted) }
        )
        statuses[.accessibility] = .denied
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            requestPermissionSetup: { _, _, _ in },
            permissionStatus: { statuses[$0] ?? .granted },
            makeIntroController: { intro },
            reduceMotion: { true }
        )

        controller.showIfNeeded()
        intro.performPermissionAction()
        NotificationCenter.default.post(
            name: .relayPermissionSetupEndedWithoutGrant,
            object: PermissionSetupLifecycleEvent(permission: .accessibility, source: .onboarding)
        )
        drainMainQueue()

        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.accessibility, .accessibility])
    }

    func testPostOnboardingPermissionLossDoesNotOpenOnboarding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        try Data().write(to: flagURLs.sessionRun)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            permissionStatus: { _ in .denied },
            makeIntroController: { intro },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(intro.presentCallCount, 0)
        XCTAssertTrue(intro.permissionPrompts.isEmpty)
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)
        XCTAssertFalse(presentation.isPresented)
    }

    func testManualRedoOnCompletedInstallKeepsExistingConfigUntilUserActsAndShowsWorkspaceLast() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        let intro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var providerWrites: [GeneralConfig.AgentProvider] = []
        var workingDirectoryWrites: [String] = []
        var firstRunExperienceStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            getAgentProvider: { .claude },
            setAgentProvider: { providerWrites.append($0) },
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            setFirstRunExperienceActive: { firstRunExperienceStates.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/new-workspace") }
            },
            reduceMotion: { true }
        )

        controller.showManualRedo()

        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(intro.events, ["cinematic"])
        XCTAssertEqual(firstRunExperienceStates, [true])
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)
        XCTAssertTrue(providerWrites.isEmpty)
        XCTAssertTrue(workingDirectoryWrites.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.manualRedo.path))

        intro.completeCinematic()
        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.claude])

        intro.performClaudeAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(providerWrites, [.claude])
        XCTAssertEqual(intro.runtimePrompts.last?.provider, .claude)
        XCTAssertEqual(intro.loginPrompts.last?.provider, .claude)
        XCTAssertEqual(intro.workspacePromptPaths, ["/Users/example/current"])

        intro.performWorkspaceAction()

        XCTAssertEqual(workingDirectoryWrites, ["/Users/example/new-workspace"])
        completeSessionControlsTutorial(controller)
        XCTAssertEqual(firstRunExperienceStates, [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.manualRedo.path))
    }

    func testManualRedoRelaunchDuringPermissionSetupRestoresAgentAndWorkspaceStages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.granted) }
        )
        statuses[.screenRecording] = .denied
        let firstIntro = CapturingIntroPresenter()
        var permissionRequests: [PermissionKind] = []
        let firstController = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getAgentProvider: { .claude },
            requestPermissionSetup: { kind, _, _ in permissionRequests.append(kind) },
            permissionStatus: { statuses[$0] ?? .denied },
            makeIntroController: { firstIntro },
            reduceMotion: { false }
        )

        firstController.showManualRedo()
        firstIntro.completeCinematic()
        XCTAssertEqual(firstIntro.permissionPrompts.map(\.permission), [.screenRecording])
        firstIntro.performPermissionAction()
        XCTAssertEqual(permissionRequests, [.screenRecording])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.manualRedo.path))

        statuses[.screenRecording] = .granted
        let resumedIntro = CapturingIntroPresenter()
        let installer = FakeRuntimeInstaller(installStatus: .succeeded)
        var providerWrites: [GeneralConfig.AgentProvider] = []
        var workspaceWrites: [String] = []
        var firstRunExperienceStates: [Bool] = []
        let resumedController = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            getAgentProvider: { .claude },
            setAgentProvider: { providerWrites.append($0) },
            setWorkingDirectory: { workspaceWrites.append($0) },
            setFirstRunExperienceActive: { firstRunExperienceStates.append($0) },
            permissionStatus: { statuses[$0] ?? .denied },
            makeIntroController: { resumedIntro },
            makeVenvInstaller: { installer },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/recovered-workspace") }
            },
            reduceMotion: { true }
        )

        resumedController.showIfNeeded()

        XCTAssertEqual(firstRunExperienceStates, [true])
        XCTAssertTrue(resumedIntro.permissionPrompts.isEmpty)
        XCTAssertEqual(resumedIntro.agentChoiceSelectedProviders, [.claude])
        resumedIntro.performClaudeAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(providerWrites, [.claude])
        XCTAssertEqual(resumedIntro.loginPrompts.last?.provider, .claude)
        XCTAssertEqual(resumedIntro.workspacePromptPaths, ["/Users/example/current"])

        resumedIntro.performWorkspaceAction()

        XCTAssertEqual(workspaceWrites, ["/Users/example/recovered-workspace"])
        completeSessionControlsTutorial(resumedController)
        XCTAssertEqual(firstRunExperienceStates, [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.manualRedo.path))
    }

    func testManualRedoRelaunchFromReadyResumeStateStillRequiresWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        try Data().write(to: flagURLs.onboarded)
        try Data().write(to: flagURLs.agentChoice)
        try Data().write(to: flagURLs.manualRedo)
        OnboardingResumeState.save(
            step: .ready,
            provider: .claude,
            parentPermissionsReviewed: true
        )
        let intro = CapturingIntroPresenter()
        var workspaceWrites: [String] = []
        var firstRunExperienceStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            setWorkingDirectory: { workspaceWrites.append($0) },
            setFirstRunExperienceActive: { firstRunExperienceStates.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/recovered-workspace") }
            },
            reduceMotion: { true }
        )

        controller.showIfNeeded()

        XCTAssertEqual(firstRunExperienceStates, [true])
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)
        XCTAssertEqual(intro.workspacePromptPaths, ["/Users/example/current"])
        intro.performWorkspaceAction()

        XCTAssertEqual(workspaceWrites, ["/Users/example/recovered-workspace"])
        completeSessionControlsTutorial(controller)
        XCTAssertEqual(firstRunExperienceStates, [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.manualRedo.path))
    }

    func testRepeatedManualRedoKeepsActiveIntroWithoutSettingsPresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flagURLs = OnboardingFlagURLs.testURLs(in: directory)
        let intro = CapturingIntroPresenter()
        let presentation = OnboardingPresentationState()
        var firstRunExperienceStates: [Bool] = []
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            presentation: presentation,
            setFirstRunExperienceActive: { firstRunExperienceStates.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            reduceMotion: { true }
        )

        controller.showManualRedo()
        let firstSerial = presentation.presentationSerial
        controller.showManualRedo()

        XCTAssertEqual(firstSerial, 0)
        XCTAssertEqual(presentation.presentationSerial, firstSerial)
        XCTAssertFalse(presentation.isPresented)
        XCTAssertEqual(intro.presentCallCount, 1)
        XCTAssertEqual(firstRunExperienceStates, [true])
        XCTAssertTrue(intro.agentChoiceSelectedProviders.isEmpty)

        intro.completeCinematic()
        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.codex])
    }

    func testGrantPermissionActionWorksAcrossThreeCompletedManualRedos() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let intros = (0..<3).map { _ in CapturingIntroPresenter() }
        var introIndex = 0
        var cancellationSources: [PermissionSetupSource?] = []
        var requests: [(PermissionKind, PermissionSetupSource)] = []
        var statuses = Dictionary(
            uniqueKeysWithValues: PermissionKind.guidedSetupOrder.map { ($0, PermissionStatus.granted) }
        )
        statuses[.microphone] = .denied
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: .testURLs(in: directory),
            getAgentProvider: { .codex },
            setWorkingDirectory: { _ in },
            requestPermissionSetup: { kind, source, _ in requests.append((kind, source)) },
            cancelPermissionSetup: { cancellationSources.append($0) },
            permissionStatus: { statuses[$0] ?? .denied },
            makeIntroController: {
                defer { introIndex += 1 }
                return intros[introIndex]
            },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/workspace") }
            },
            reduceMotion: { false }
        )

        for (index, intro) in intros.enumerated() {
            controller.showManualRedo()
            XCTAssertEqual(cancellationSources.last!, .onboarding)
            XCTAssertEqual(intro.presentCallCount, 1)

            intro.completeCinematic()
            XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone])
            intro.performPermissionAction()
            XCTAssertEqual(requests.map(\.0), Array(repeating: .microphone, count: index + 1))
            XCTAssertEqual(requests.last?.1, .onboarding)

            statuses[.microphone] = .granted
            postGrant(.microphone)
            drainMainQueue()
            intro.performCodexAction()
            waitForMainQueue(after: 0.05)
            XCTAssertEqual(intro.workspacePromptPaths, [NSHomeDirectory()])

            intro.performWorkspaceAction()
            completeSessionControlsTutorial(controller)
            XCTAssertEqual(introIndex, index + 1)
            statuses[.microphone] = .denied
        }

        XCTAssertEqual(
            cancellationSources.compactMap { $0 }.filter { $0 == .onboarding }.count,
            6
        )
    }

    func testOnboardingControllerDoesNotDefineDedicatedWindowSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("OnboardingSurfaceControlling"))
        XCTAssertFalse(contents.contains("OnboardingNotchSurfaceController"))
        XCTAssertFalse(contents.contains("OnboardingNotchPanel"))
        XCTAssertFalse(contents.contains("NSPanel"))
        XCTAssertFalse(contents.contains("setActivationPolicy"))
    }

    func testIntroRecreatesAKeyEligiblePanelForInteractivePermissionActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingIntroController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("let p = BoardOverlayPanel()"))
        XCTAssertTrue(contents.contains("p.keyEligible = true"))
        XCTAssertTrue(contents.contains("p.makeKey()"))
    }

    func testOnboardingControllerDoesNotConstructSettingsHostedOnboarding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("OnboardingView("))
        XCTAssertFalse(contents.contains("presentation.present("))
        XCTAssertFalse(contents.contains("openSettingsHost"))
        XCTAssertFalse(contents.contains("setModel("))
        XCTAssertFalse(contents.contains("setCodexReasoningEffort("))
    }

    func testRevealCompletionStartsTimelineOnlyWhenSurfaceIsStillActive() {
        XCTAssertEqual(
            OnboardingIntroPolicy.completionPlan(
                revealCompleted: true,
                skipRequested: false,
                timelineComplete: false,
                isCompleting: false
            ),
            OnboardingIntroCompletionPlan(
                startsTimeline: true,
                cleansUpSurface: false,
                performsHandoff: false
            )
        )
        XCTAssertFalse(OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: false,
            isCompleting: true
        ).startsTimeline)
    }

    func testSkipAndTimelineCompletionUseSameHandoffPlanWithoutCleanup() {
        let skip = OnboardingIntroPolicy.completionPlan(
            revealCompleted: false,
            skipRequested: true,
            timelineComplete: false,
            isCompleting: false
        )
        let complete = OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: true,
            isCompleting: false
        )

        XCTAssertEqual(skip.cleansUpSurface, false)
        XCTAssertEqual(skip.performsHandoff, true)
        XCTAssertEqual(complete, skip)
    }

    func testTimelineTypesHoldsAndErasesFirstPhrase() {
        let first = OnboardingIntroTimeline.phrases[0]
        let firstCount = Double(Array(first).count)
        let brandTypeDuration = (firstCount - 1) * OnboardingIntroTimeline.typingInterval

        XCTAssertEqual(OnboardingIntroTimeline.frame(at: 0).text, "R/")
        XCTAssertTrue(OnboardingIntroTimeline.frame(at: 0).cursorVisible)
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(
                at: OnboardingIntroTimeline.initialBrandHold
                    + OnboardingIntroTimeline.typingInterval
                    + 0.001
            ).text,
            "Re /"
        )

        let full = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold + brandTypeDuration
        )
        XCTAssertEqual(full.activePhrase, first)
        XCTAssertEqual(full.text, "\(first) /")
        XCTAssertEqual(full.dotFieldProgress, 0, accuracy: 0.001)
        XCTAssertEqual(full.dotFieldOpacity, 0, accuracy: 0.001)

        let holding = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel / 2
        )
        XCTAssertEqual(holding.text, "\(first) /")
        XCTAssertEqual(holding.dotFieldProgress, 0.5, accuracy: 0.01)
        XCTAssertEqual(holding.dotFieldOpacity, 0.5, accuracy: 0.01)

        let erased = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel
                + OnboardingIntroTimeline.brandSettle
                + firstCount * OnboardingIntroTimeline.eraseInterval
                - 0.001
        )
        XCTAssertEqual(erased.text, "R/")
        XCTAssertFalse(erased.isComplete)
    }

    func testBrandSettlesThenErasesAtTheSamePerGraphemeCadenceAsItsEntrance() {
        let brandPhrase = OnboardingIntroTimeline.phrases[0]
        let brandCount = Double(Array(brandPhrase).count)
        let settleStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval
            + OnboardingIntroTimeline.dotFieldTravel
        let eraseStart = settleStart + OnboardingIntroTimeline.brandSettle

        XCTAssertEqual(
            OnboardingIntroTimeline.frame(
                at: settleStart + OnboardingIntroTimeline.brandSettle - 0.001
            ).text,
            "Relay Runner /"
        )
        XCTAssertEqual(OnboardingIntroTimeline.eraseInterval, OnboardingIntroTimeline.typingInterval)
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(at: eraseStart).text,
            "Relay Runner /"
        )
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(
                at: eraseStart + OnboardingIntroTimeline.eraseInterval + 0.001
            ).text,
            "Relay Runne /"
        )
        XCTAssertEqual(
            OnboardingIntroTimeline.frame(
                at: eraseStart + brandCount * OnboardingIntroTimeline.eraseInterval - 0.001
            ).text,
            "R/"
        )
    }

    func testCursorBlinksWhileHoldingCopy() {
        let brandCount = Double(Array(OnboardingIntroTimeline.phrases[0]).count)
        let holdStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval
        let nextBlinkPeriod = ceil(holdStart / OnboardingIntroTimeline.cursorBlinkPeriod)
            * OnboardingIntroTimeline.cursorBlinkPeriod

        let visible = OnboardingIntroTimeline.frame(at: nextBlinkPeriod + 0.10)
        let hidden = OnboardingIntroTimeline.frame(
            at: nextBlinkPeriod + OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.10
        )

        XCTAssertTrue(visible.cursorVisible)
        XCTAssertEqual(visible.renderedText, "Relay Runner /")
        XCTAssertEqual(visible.cursorOpacity, 1)
        XCTAssertFalse(hidden.cursorVisible)
        XCTAssertEqual(hidden.renderedText, "Relay Runner /")
        XCTAssertEqual(hidden.cursorOpacity, 0.5)
    }

    func testCursorKeepsBlinkingWhileTypingAndBackspacing() {
        let typingStart = OnboardingIntroTimeline.initialBrandHold
        let typedVisible = OnboardingIntroTimeline.frame(at: typingStart + 0.01)
        let typedHidden = OnboardingIntroTimeline.frame(
            at: typingStart + OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
        )
        XCTAssertNotEqual(typedVisible.cursorVisible, typedHidden.cursorVisible)

        let source = "I need a few permissions /"
        let target = "Let’s start with your mic /"
        let eraseStart = OnboardingPromptTransitionTimeline.initialHold
        let erasedVisible = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: eraseStart + 0.01
        )
        let erasedHidden = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: eraseStart + OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
        )
        XCTAssertNotEqual(erasedVisible.cursorVisible, erasedHidden.cursorVisible)
    }

    func testHostedOnboardingTitlesBlinkTheirSlashWithoutChangingCopy() {
        XCTAssertEqual(
            OnboardingBlinkingTitle.renderedText("Choose your workspace /", at: 0),
            "Choose your workspace /"
        )
        XCTAssertEqual(
            OnboardingBlinkingTitle.renderedText(
                "Choose your workspace /",
                at: OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
            ),
            "Choose your workspace /"
        )
        XCTAssertEqual(OnboardingBlinkingTitle.cursorOpacity(at: 0), 1)
        XCTAssertLessThan(
            OnboardingBlinkingTitle.cursorOpacity(
                at: OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
            ),
            0.52
        )
        XCTAssertGreaterThan(
            OnboardingBlinkingTitle.cursorOpacity(
                at: OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
            ),
            OnboardingCursorBlink.minimumOpacity
        )
    }

    func testTimelineCompletesOnFinalPermissionPhrase() {
        let complete = OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.duration)

        XCTAssertEqual(complete.activePhrase, "I need a few permissions")
        XCTAssertEqual(complete.text, "I need a few permissions /")
        XCTAssertTrue(complete.isComplete)
    }

    func testPermissionPromptTransitionBackspacesThenTypesOnTheHeroBaseline() {
        let source = "I need a few permissions /"
        let target = "Let’s start with your mic /"
        let sourceCount = Double(OnboardingPromptTransitionTimeline.phrase(from: source).count)
        let eraseStart = OnboardingPromptTransitionTimeline.initialHold
        let typeStart = eraseStart + sourceCount * OnboardingPromptTransitionTimeline.eraseInterval

        XCTAssertEqual(
            OnboardingPromptTransitionTimeline.frame(from: source, to: target, at: 0).text,
            source
        )

        let backspacing = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: eraseStart + OnboardingPromptTransitionTimeline.eraseInterval + 0.001
        )
        XCTAssertTrue(backspacing.text.hasSuffix(" /"))
        XCTAssertLessThan(backspacing.text.count, source.count)

        let typing = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: typeStart
                + Double(OnboardingPromptTransitionTimeline.phrase(from: target).count)
                * OnboardingPromptTransitionTimeline.typingInterval
                * 0.60
        )
        XCTAssertTrue(typing.text.hasPrefix("Let’s"))
        XCTAssertFalse(typing.isComplete)

        let complete = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: OnboardingPromptTransitionTimeline.duration(from: source, to: target) + 0.001
        )
        XCTAssertEqual(complete.text, target)
        XCTAssertTrue(complete.isComplete)

        let layoutHeight = BoardRevealTransitionPlanner.expandedSurfaceHeight
        let textRect = OnboardingIntroTextLayout.drawRect(
            in: CGRect(x: 0, y: 0, width: 1512, height: layoutHeight),
            reserveWidth: 640,
            visibleWidth: 420
        )
        XCTAssertEqual(
            OnboardingIntroTextLayout.permissionControlsTop(forHeight: layoutHeight),
            textRect.minY
                + (OnboardingIntroTextLayout.lineHeight + 54)
                * (layoutHeight / OnboardingIntroTextLayout.referenceWorkspaceHeight),
            accuracy: 0.001
        )
    }

    func testOnlyTutorialUsesOpacityPromptTransitions() {
        let opacityPhases = OnboardingPromptPhase.allCases.filter {
            $0.transitionPolicy == .opacity
        }

        XCTAssertEqual(opacityPhases, [.tutorial])
        for phase in OnboardingPromptPhase.allCases where phase != .tutorial {
            XCTAssertEqual(phase.transitionPolicy, .cursorLed)
        }
    }

    func testPromptTransitionPreservesUnicodeGraphemesAcrossInterruptionAndReentry() {
        let source = "Preparing 👩🏽‍💻 /"
        let target = "Codex is ready /"
        XCTAssertEqual(
            OnboardingPromptTransitionTimeline.phrase(from: source),
            Array("Preparing 👩🏽‍💻")
        )

        let interrupted = OnboardingPromptTransitionTimeline.frame(
            from: source,
            to: target,
            at: OnboardingPromptTransitionTimeline.duration(from: source, to: target) * 0.45
        )
        let reentered = OnboardingPromptTransitionTimeline.frame(
            from: interrupted.text,
            to: "Choose your workspace /",
            at: 0
        )
        XCTAssertEqual(reentered.text, interrupted.text)

        let complete = OnboardingPromptTransitionTimeline.frame(
            from: interrupted.text,
            to: "Choose your workspace /",
            at: OnboardingPromptTransitionTimeline.duration(
                from: interrupted.text,
                to: "Choose your workspace /"
            ) + 0.001
        )
        XCTAssertEqual(complete.text, "Choose your workspace /")
        XCTAssertTrue(complete.isComplete)
    }

    func testReduceMotionResolvesPromptTransitionDirectlyToFinalCopy() {
        let source = "Preparing Codex /"
        let target = "Codex is ready /"

        let animated = OnboardingPromptTransitionTimeline.presentationFrame(
            from: source,
            to: target,
            at: 0,
            reduceMotion: false
        )
        let reduced = OnboardingPromptTransitionTimeline.presentationFrame(
            from: source,
            to: target,
            at: 0,
            reduceMotion: true
        )

        XCTAssertEqual(animated.text, source)
        XCTAssertFalse(animated.isComplete)
        XCTAssertEqual(reduced.text, target)
        XCTAssertTrue(reduced.isComplete)
    }

    func testRuntimeAndLoginPromptCopyUsesTheSamePolicyForCodexAndClaude() {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            let preparing = OnboardingIntroPromptCopy.runtime(
                OnboardingRuntimePromptPresentation(provider: provider, status: .idle)
            )
            let ready = OnboardingIntroPromptCopy.runtime(
                OnboardingRuntimePromptPresentation(provider: provider, status: .succeeded)
            )
            let failed = OnboardingIntroPromptCopy.runtime(
                OnboardingRuntimePromptPresentation(
                    provider: provider,
                    status: .failed(message: "Unavailable")
                )
            )
            let login = OnboardingIntroPromptCopy.agentLogin(
                OnboardingAgentLoginPromptPresentation(
                    provider: provider,
                    signedIn: false,
                    message: nil
                )
            )

            XCTAssertEqual(preparing, "Preparing \(provider.displayName) /")
            XCTAssertEqual(ready, "\(provider.displayName) is ready /")
            XCTAssertEqual(failed, "\(provider.displayName) setup needs attention /")
            XCTAssertEqual(login, "Sign in to \(provider.displayName) /")
        }
    }

    func testTimelineUsesReadablePacingTargets() {
        XCTAssertEqual(OnboardingIntroTimeline.typingInterval, 0.065 / 2.25, accuracy: 0.001)
        XCTAssertEqual(OnboardingIntroTimeline.eraseInterval, OnboardingIntroTimeline.typingInterval)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.initialBrandHold, 0.65)
        XCTAssertEqual(
            OnboardingIntroTimeline.brandSettle,
            OnboardingPromptTransitionTimeline.initialHold
        )
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.phraseHold, 1.0)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.finalPhraseHold, 1.4)
        XCTAssertEqual(OnboardingIntroTimeline.dotFieldTravel, 4.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.duration, 10.0)
        XCTAssertLessThanOrEqual(OnboardingIntroTimeline.duration, 10.4)
        XCTAssertGreaterThanOrEqual(OnboardingPromptTransitionTimeline.initialHold, 0.35)
        XCTAssertGreaterThanOrEqual(OnboardingPromptTransitionTimeline.finalHold, 0.30)
        XCTAssertGreaterThanOrEqual(OnboardingFlowMotion.surfaceTransitionDuration, 0.45)
        XCTAssertGreaterThanOrEqual(OnboardingFlowMotion.controlsRevealDuration, 0.35)
        XCTAssertGreaterThan(
            OnboardingFlowMotion.completedStepHold,
            OnboardingFlowMotion.surfaceTransitionDuration
        )
    }

    func testRuntimeInstallSurfaceOmitsTechnicalProgressSubtitlesAndEasesStateChanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingIntroController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)
        let runtimeStart = try XCTUnwrap(contents.range(of: "private struct OnboardingIntroRuntimePromptView"))
        let loginStart = try XCTUnwrap(contents.range(
            of: "struct OnboardingIntroAgentLoginPromptView",
            range: runtimeStart.upperBound..<contents.endIndex
        ))
        let runtimeSource = String(contents[runtimeStart.lowerBound..<loginStart.lowerBound])

        XCTAssertFalse(runtimeSource.contains("Starting setup..."))
        XCTAssertFalse(runtimeSource.contains("Runtime and "))
        XCTAssertFalse(runtimeSource.contains("case .running(let message"))
        XCTAssertTrue(runtimeSource.contains("case .failed(let errorMessage)"))
        XCTAssertTrue(runtimeSource.contains("OnboardingFlowMotion.contentAnimation"))
        XCTAssertFalse(runtimeSource.contains("transitioningTitle"))
        XCTAssertFalse(runtimeSource.contains(".id(title)"))
        XCTAssertTrue(contents.contains("OnboardingIntroRuntimeSurfaceModel"))
        XCTAssertTrue(contents.contains("OnboardingIntroPromptSurfaceView"))
        XCTAssertTrue(
            contents.contains(
                "policy: OnboardingPromptPhase.tutorial.transitionPolicy"
            )
        )
        XCTAssertTrue(contents.contains("CAMediaTimingFunction(name: .easeInEaseOut)"))
    }

    func testFreshInteractiveHandoffCanStartAtAgentChoice() {
        let step = OnboardingView.initialStep(
            simplified: false,
            resumeStep: nil,
            requiresAgentChoice: true,
            requiresParentPermissionGuidance: false,
            parentPermissionsReviewed: false,
            permissionStatus: { _ in .granted },
            venvInstalled: true,
            agentSignedIn: true,
            fullFlowInitialStep: .agentChoice
        )

        XCTAssertEqual(step, .agentChoice)
    }

    func testPermissionSurfaceVisibilityHidesOnlyWhileMatchingSetupIsActive() {
        XCTAssertTrue(OnboardingView.initialSurfaceVisible(for: .microphone))
        XCTAssertFalse(OnboardingView.surfaceVisible(
            for: .microphone,
            activePermissionSetupKind: .microphone
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .microphone,
            activePermissionSetupKind: nil
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .agentChoice,
            activePermissionSetupKind: .microphone
        ))
    }

    func testHeroTextLayoutMatchesReferenceTopWithinRevealSurface() {
        assertHeroTextLayoutMatchesReferenceFrame(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )
    }

    func testHeroTextLayoutKeepsReferenceTopWithinTallerRevealSurface() {
        assertHeroTextLayoutMatchesReferenceFrame(
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1600)
        )
    }

    func testHeroTextLayoutCentersWithinShortClampedRevealSurface() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 420)

        assertHeroTextLayoutMatchesReferenceFrame(screen: screen)
        XCTAssertEqual(
            BoardRevealTransitionPlanner.plan(for: screen).expandedFrame.height,
            screen.height - BoardRevealTransitionPlanner.bottomScreenMargin
        )
    }

    func testIntroUsesSharedParticleRendererInsteadOfOnboardingHalftone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingIntroController.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("ParticleFieldRenderer()"))
        XCTAssertTrue(contents.contains("renderer.transition(to: .tts)"))
        XCTAssertTrue(contents.contains("particleClipView.layer?.masksToBounds = true"))
        XCTAssertTrue(contents.contains("particleClipView.addSubview(particleHost)"))
        XCTAssertTrue(contents.contains("particleHost.frame = particleClipView.bounds"))
        XCTAssertFalse(contents.contains("layer?.transform = CATransform3DMakeTranslation"))
        XCTAssertTrue(contents.contains("paragraph.alignment = .center"))
        XCTAssertTrue(contents.contains(".onHover { isHovering = $0 }"))
        XCTAssertTrue(contents.contains(".animation(Self.hoverAnimation, value: showsHover)"))
        XCTAssertFalse(contents.contains("OnboardingHalftone"))
        XCTAssertFalse(contents.contains("drawHalftone"))
        XCTAssertFalse(contents.contains(".scaleEffect(showsHover"))
    }

    func testParticleOpacityRampsInAndOutWithMessagePlayback() {
        let firstCount = Double(Array(OnboardingIntroTimeline.phrases[0]).count)
        let travelStart = OnboardingIntroTimeline.initialBrandHold
            + (firstCount - 1) * OnboardingIntroTimeline.typingInterval
        let eraseStart = travelStart + OnboardingIntroTimeline.dotFieldTravel
            + OnboardingIntroTimeline.brandSettle
        let eraseDuration = firstCount * OnboardingIntroTimeline.eraseInterval

        let hidden = OnboardingIntroTimeline.frame(at: travelStart)
        let appearing = OnboardingIntroTimeline.frame(at: travelStart + OnboardingIntroTimeline.dotFieldTravel * 0.25)
        let visible = OnboardingIntroTimeline.frame(at: eraseStart)
        let disappearing = OnboardingIntroTimeline.frame(at: eraseStart + eraseDuration * 0.50)
        let gone = OnboardingIntroTimeline.frame(at: eraseStart + eraseDuration + 0.001)

        XCTAssertEqual(hidden.dotFieldOpacity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(appearing.dotFieldOpacity, 0)
        XCTAssertLessThan(appearing.dotFieldOpacity, 0.5)
        XCTAssertEqual(visible.dotFieldOpacity, 1, accuracy: 0.001)
        XCTAssertGreaterThan(disappearing.dotFieldOpacity, 0)
        XCTAssertLessThan(disappearing.dotFieldOpacity, 1)
        XCTAssertEqual(gone.dotFieldOpacity, 0, accuracy: 0.001)
    }

    func testWorkspaceControlsShareVisibleHeightAndCompletionSlashDoesNotChangeCopyWidth() {
        XCTAssertEqual(
            OnboardingIntroWorkspacePromptView.controlHeight,
            52 * OnboardingPermissionTreatment.actionScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OnboardingBlinkingTitle.renderedText("You’re all set /", at: 0),
            "You’re all set /"
        )
        XCTAssertEqual(
            OnboardingBlinkingTitle.renderedText(
                "You’re all set /",
                at: OnboardingIntroTimeline.cursorBlinkPeriod / 2 + 0.01
            ),
            "You’re all set /"
        )
    }

    func testOnboardingActionHoverKeepsFootprintStable() {
        XCTAssertEqual(OnboardingIntroWhiteActionButton.hoverScale, 1, accuracy: 0.001)
    }

    private func assertHeroTextLayoutMatchesReferenceFrame(
        screen: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = BoardRevealTransitionPlanner.plan(for: screen)
        let rect = OnboardingIntroTextLayout.drawRect(
            in: plan.expandedFrame,
            reserveWidth: 640,
            visibleWidth: 420
        )

        XCTAssertEqual(rect.midX, plan.expandedFrame.midX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(
            rect.minY,
            plan.expandedFrame.minY
                + OnboardingIntroTextLayout.referenceTextTop
                * (plan.expandedFrame.height / OnboardingIntroTextLayout.referenceWorkspaceHeight),
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertNotEqual(rect.midY, screen.midY, accuracy: 0.001, file: file, line: line)
    }

    private func makeSessionControlsTutorialController(
        flagURLs: OnboardingFlagURLs,
        intro: CapturingIntroPresenter,
        prepareTutorialSpeech: @escaping () -> Bool = { true },
        workspaceOpen: @escaping () -> Void = {}
    ) -> OnboardingController {
        OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            setWorkingDirectory: { _ in },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { FakeRuntimeInstaller(installStatus: .succeeded) },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            pickWorkspaceDirectory: { prepare, completion in
                prepare { completion("/Users/example/dev") }
            },
            reduceMotion: { true },
            prepareTutorialSpeech: prepareTutorialSpeech,
            openWorkspaceAfterCompletion: workspaceOpen
        )
    }

    private func beginSessionControlsTutorial(
        _ controller: OnboardingController,
        intro: CapturingIntroPresenter,
        provider: GeneralConfig.AgentProvider
    ) {
        controller.showIfNeeded()
        switch provider {
        case .codex:
            intro.performCodexAction()
        case .claude:
            intro.performClaudeAction()
        }
        waitForMainQueue(after: 0.05)
        intro.performWorkspaceAction()
        drainMainQueue()
    }

    private func completeSessionControlsTutorial(_ controller: OnboardingController) {
        drainMainQueue()
        controller.noteTutorialRecordingStarted()
        controller.noteTutorialSpeechDetected()
        controller.noteTutorialRecordingSent()
        controller.noteTutorialResponseReady("Hello, how are you?")
        controller.noteTutorialPlaybackRequested()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialPlaybackFinished()
        controller.noteTutorialPlaybackStarted()
        controller.noteTutorialCancelRequested()
        controller.noteTutorialWorkspaceToggled()
        drainMainQueue()
    }
}

private final class CapturingIntroPresenter: OnboardingIntroPresenting {
    private(set) var presentCallCount = 0
    private(set) var events: [String] = []
    private(set) var permissionPrompts: [OnboardingPermissionPromptPresentation] = []
    private(set) var agentChoiceSelectedProviders: [GeneralConfig.AgentProvider] = []
    private(set) var runtimePrompts: [OnboardingRuntimePromptPresentation] = []
    private(set) var loginPrompts: [OnboardingAgentLoginPromptPresentation] = []
    private(set) var workspacePromptPaths: [String] = []
    private(set) var tutorialPresentations: [OnboardingTutorialPresentation] = []
    private var cinematicCompletion: (() -> Void)?
    private var permissionAction: (() -> Void)?
    private var codexAction: (() -> Void)?
    private var claudeAction: (() -> Void)?
    private var runtimeRetryAction: (() -> Void)?
    private var loginAction: (() -> Void)?
    private var workspaceContinueAction: (() -> Void)?
    private var workspaceAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    func present(completion: @escaping () -> Void) {
        presentCallCount += 1
        events.append("cinematic")
        cinematicCompletion = completion
    }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {
        events.append("permission:\(presentation.permission.rawValue)")
        permissionPrompts.append(presentation)
        permissionAction = action
    }

    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void) {
        events.append("agentChoice:\(selectedProvider.rawValue)")
        agentChoiceSelectedProviders.append(selectedProvider)
        self.codexAction = codexAction
        self.claudeAction = claudeAction
    }

    func presentRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                              retryAction: @escaping () -> Void) {
        events.append("runtime:\(presentation.provider.rawValue)")
        runtimePrompts.append(presentation)
        runtimeRetryAction = retryAction
    }

    func presentAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                                 signInAction: @escaping () -> Void) {
        events.append("login:\(presentation.provider.rawValue):\(presentation.signedIn)")
        loginPrompts.append(presentation)
        loginAction = signInAction
    }

    func presentWorkspacePrompt(currentPath: String,
                                continueAction: @escaping () -> Void,
                                browseAction: @escaping () -> Void) {
        events.append("workspace")
        workspacePromptPaths.append(currentPath)
        workspaceContinueAction = continueAction
        workspaceAction = browseAction
    }

    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void) {
        events.append("tutorial:\(presentation.screen.rawValue)")
        tutorialPresentations.append(presentation)
        runtimeRetryAction = retryAction
    }

    func dismiss(completion: @escaping () -> Void) {
        onDismiss?()
        completion()
    }

    func completeCinematic() {
        cinematicCompletion?()
        cinematicCompletion = nil
    }

    func performPermissionAction() {
        permissionAction?()
    }

    func performCodexAction() {
        codexAction?()
    }

    func performClaudeAction() {
        claudeAction?()
    }

    func performRuntimeRetry() {
        runtimeRetryAction?()
    }

    func performLoginAction() {
        loginAction?()
    }

    func performWorkspaceContinueAction() {
        workspaceContinueAction?()
    }

    func performWorkspaceAction() {
        workspaceAction?()
    }

}

private final class DeferredDismissIntroPresenterFactory {
    weak var presenter: DeferredDismissIntroPresenter?

    private let eventSink: (String) -> Void

    init(eventSink: @escaping (String) -> Void) {
        self.eventSink = eventSink
    }

    func makePresenter() -> any OnboardingIntroPresenting {
        let presenter = DeferredDismissIntroPresenter(eventSink: eventSink)
        self.presenter = presenter
        return presenter
    }
}

private final class DeferredDismissIntroPresenter: OnboardingIntroPresenting {
    private let eventSink: (String) -> Void
    private var codexAction: (() -> Void)?
    private var workspaceContinueAction: (() -> Void)?
    private var workspaceAction: (() -> Void)?
    private var dismissCompletion: (() -> Void)?
    private var defersDismissal = false

    init(eventSink: @escaping (String) -> Void) {
        self.eventSink = eventSink
    }

    deinit {
        eventSink("deinit")
    }

    func present(completion: @escaping () -> Void) {
        completion()
    }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {}

    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void) {
        self.codexAction = codexAction
    }

    func presentRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                              retryAction: @escaping () -> Void) {}

    func presentAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                                 signInAction: @escaping () -> Void) {}

    func presentWorkspacePrompt(currentPath: String,
                                continueAction: @escaping () -> Void,
                                browseAction: @escaping () -> Void) {
        workspaceContinueAction = continueAction
        workspaceAction = browseAction
    }

    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void) {
        if presentation.screen == .workspace {
            defersDismissal = true
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        eventSink("dismiss")
        guard defersDismissal else {
            completion()
            return
        }
        defersDismissal = false
        dismissCompletion = completion
    }

    func performCodexAction() {
        codexAction?()
    }

    func performWorkspaceAction() {
        workspaceAction?()
    }

    func performWorkspaceContinueAction() {
        workspaceContinueAction?()
    }

    func completeDismissal() {
        let completion = dismissCompletion
        dismissCompletion = nil
        completion?()
    }
}

private final class FakeRuntimeInstaller: OnboardingRuntimeInstalling {
    private(set) var installProviders: [GeneralConfig.AgentProvider?] = []
    private let installStatus: VenvInstaller.Status
    var status: VenvInstaller.Status

    init(status: VenvInstaller.Status = .idle,
         installStatus: VenvInstaller.Status = .idle) {
        self.status = status
        self.installStatus = installStatus
    }

    func install(for provider: GeneralConfig.AgentProvider?) {
        installProviders.append(provider)
        status = installStatus
    }
}

private func postGrant(_ permission: PermissionKind) {
    NotificationCenter.default.post(
        name: .relayPermissionSetupGrantReady,
        object: permission.rawValue
    )
}

private func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) {
    let expectation = XCTestExpectation(description: "Drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1)
}

private func waitForMainQueue(after delay: TimeInterval,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
    let expectation = XCTestExpectation(description: "Wait for main queue")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        expectation.fulfill()
    }
    let result = XCTWaiter().wait(for: [expectation], timeout: delay + 1)
    XCTAssertEqual(result, .completed, file: file, line: line)
}

private extension OnboardingFlagURLs {
    static func testURLs(in directory: URL) -> OnboardingFlagURLs {
        OnboardingFlagURLs(
            onboarded: directory.appendingPathComponent(".onboarded"),
            architectureVersion: directory.appendingPathComponent(".onboarding-architecture-version"),
            started: directory.appendingPathComponent(".onboarding-started"),
            sessionRun: directory.appendingPathComponent(".session-run"),
            agentChoice: directory.appendingPathComponent(".agent-choice-v1"),
            manualRedo: directory.appendingPathComponent(".onboarding-manual-redo")
        )
    }
}
