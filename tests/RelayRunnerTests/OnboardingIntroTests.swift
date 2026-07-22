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
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [.microphone, .accessibility, .inputMonitoring])

        intro.performPermissionAction()
        statuses[.inputMonitoring] = .granted
        postGrant(.inputMonitoring)
        drainMainQueue()
        XCTAssertEqual(intro.permissionPrompts.map(\.permission), [
            .microphone,
            .accessibility,
            .inputMonitoring,
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
            reduceMotion: { true }
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

        XCTAssertEqual(Array(events.prefix(3)), ["dismiss", "notch:false", "picker"])
        XCTAssertEqual(workingDirectoryWrites, ["/Users/example/dev"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flagURLs.started.path))
        XCTAssertNil(OnboardingResumeState.load())
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
        let controller = OnboardingController(
            permissions: PermissionsManager(),
            flagURLs: flagURLs,
            getWorkingDirectory: { "/Users/example/current" },
            getAgentProvider: { .claude },
            setAgentProvider: { providerWrites.append($0) },
            setWorkingDirectory: { workingDirectoryWrites.append($0) },
            permissionStatus: { _ in .granted },
            makeIntroController: { intro },
            makeVenvInstaller: { installer },
            runtimeAlreadyInstalled: { _ in false },
            isAgentAuthenticated: { _ in true },
            runtimePollInterval: 0.01,
            introAdvanceDelay: 0,
            reduceMotion: { true }
        )

        controller.showManualRedo()

        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.claude])
        XCTAssertTrue(providerWrites.isEmpty)
        XCTAssertTrue(workingDirectoryWrites.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.onboarded.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flagURLs.agentChoice.path))

        intro.performClaudeAction()
        waitForMainQueue(after: 0.05)

        XCTAssertEqual(providerWrites, [.claude])
        XCTAssertEqual(intro.runtimePrompts.last?.provider, .claude)
        XCTAssertEqual(intro.loginPrompts.last?.provider, .claude)
        XCTAssertEqual(intro.workspacePromptPaths, ["/Users/example/current"])
    }

    func testRepeatedManualRedoKeepsActiveIntroWithoutSettingsPresentation() throws {
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
        XCTAssertEqual(intro.agentChoiceSelectedProviders, [.codex])
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
        XCTAssertEqual(full.dotFieldOpacity, 1, accuracy: 0.001)

        let holding = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel / 2
        )
        XCTAssertEqual(holding.text, "\(first) /")
        XCTAssertEqual(holding.dotFieldProgress, 0.5, accuracy: 0.01)

        let erased = OnboardingIntroTimeline.frame(
            at: OnboardingIntroTimeline.initialBrandHold
                + brandTypeDuration
                + OnboardingIntroTimeline.dotFieldTravel
                + firstCount * OnboardingIntroTimeline.eraseInterval
                - 0.001
        )
        XCTAssertEqual(erased.text, "/")
        XCTAssertFalse(erased.isComplete)
    }

    func testBrandEraseFramesMatchDesignWithoutSeparatorSpace() {
        let brandPhrase = OnboardingIntroTimeline.phrases[0]
        let brandCount = Double(Array(brandPhrase).count)
        let eraseStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval
            + OnboardingIntroTimeline.dotFieldTravel

        let rOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (brandCount - 2) * OnboardingIntroTimeline.eraseInterval + 0.001
        )
        let slashOnly = OnboardingIntroTimeline.frame(
            at: eraseStart + (brandCount - 1) * OnboardingIntroTimeline.eraseInterval + 0.001
        )

        XCTAssertEqual(rOnly.text, "R/")
        XCTAssertFalse(rOnly.isComplete)
        XCTAssertEqual(slashOnly.text, "/")
        XCTAssertFalse(slashOnly.isComplete)
    }

    func testCursorBlinksWhileHoldingCopy() {
        let brandCount = Double(Array(OnboardingIntroTimeline.phrases[0]).count)
        let holdStart = OnboardingIntroTimeline.initialBrandHold
            + (brandCount - 1) * OnboardingIntroTimeline.typingInterval

        let visible = OnboardingIntroTimeline.frame(at: holdStart + 0.10)
        let hidden = OnboardingIntroTimeline.frame(at: holdStart + 0.45)

        XCTAssertTrue(visible.cursorVisible)
        XCTAssertEqual(visible.renderedText, "Relay Runner /")
        XCTAssertFalse(hidden.cursorVisible)
        XCTAssertEqual(hidden.renderedText, "Relay Runner ")
    }

    func testTimelineCompletesOnFinalPermissionPhrase() {
        let complete = OnboardingIntroTimeline.frame(at: OnboardingIntroTimeline.duration)

        XCTAssertEqual(complete.activePhrase, "I need a few permissions")
        XCTAssertEqual(complete.text, "I need a few permissions /")
        XCTAssertTrue(complete.isComplete)
    }

    func testTimelineUsesReadablePacingTargets() {
        XCTAssertEqual(OnboardingIntroTimeline.typingInterval, 0.065, accuracy: 0.001)
        XCTAssertEqual(OnboardingIntroTimeline.eraseInterval, 0.045, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.initialBrandHold, 0.65)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.phraseHold, 1.0)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.finalPhraseHold, 1.4)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.dotFieldTravel, 1.8)
        XCTAssertLessThanOrEqual(OnboardingIntroTimeline.dotFieldTravel, 2.2)
        XCTAssertGreaterThanOrEqual(OnboardingIntroTimeline.duration, 9.5)
        XCTAssertLessThanOrEqual(OnboardingIntroTimeline.duration, 11.5)
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
        XCTAssertFalse(OnboardingView.surfaceVisible(
            for: .inputMonitoring,
            activePermissionSetupKind: .inputMonitoring
        ))
        XCTAssertTrue(OnboardingView.surfaceVisible(
            for: .inputMonitoring,
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
        XCTAssertFalse(contents.contains("OnboardingHalftone"))
        XCTAssertFalse(contents.contains("drawHalftone"))
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
}

private final class CapturingIntroPresenter: OnboardingIntroPresenting {
    private(set) var presentCallCount = 0
    private(set) var events: [String] = []
    private(set) var permissionPrompts: [OnboardingPermissionPromptPresentation] = []
    private(set) var agentChoiceSelectedProviders: [GeneralConfig.AgentProvider] = []
    private(set) var runtimePrompts: [OnboardingRuntimePromptPresentation] = []
    private(set) var loginPrompts: [OnboardingAgentLoginPromptPresentation] = []
    private(set) var workspacePromptPaths: [String] = []
    private var cinematicCompletion: (() -> Void)?
    private var permissionAction: (() -> Void)?
    private var codexAction: (() -> Void)?
    private var claudeAction: (() -> Void)?
    private var runtimeRetryAction: (() -> Void)?
    private var loginAction: (() -> Void)?
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
                                action: @escaping () -> Void) {
        events.append("workspace")
        workspacePromptPaths.append(currentPath)
        workspaceAction = action
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

    func performWorkspaceAction() {
        workspaceAction?()
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
            started: directory.appendingPathComponent(".onboarding-started"),
            sessionRun: directory.appendingPathComponent(".session-run"),
            agentChoice: directory.appendingPathComponent(".agent-choice-v1")
        )
    }
}
