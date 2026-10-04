import XCTest
import Sparkle
import SwiftUI
@testable import relay_runner

final class UpdaterTests: XCTestCase {
    @MainActor
    func testUpdateActionHidesWorkspaceBeforeFocusingAndCheckingAndAllowsReopening() throws {
        _ = NSApplication.shared
        let workspace = ProgramBoardOverlayController(boardRouteResolver: { .unavailable })
        workspace.setSettingsContentProvider { AnyView(Text("Settings")) }
        defer { workspace.suspendForExternalWindow() }
        workspace.showSettings()
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is BoardOverlayPanel && $0.isVisible })
        var checks = 0
        let updater = RelayUpdaterController(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/tmp/relay-runner"),
            focusUpdateUI: {
                XCTAssertFalse(workspace.isVisible)
                XCTAssertFalse(panel.isVisible)
            },
            scheduleUpdateUIFocus: { $0() },
            checkForUpdatesOverride: {
                XCTAssertFalse(workspace.isVisible)
                XCTAssertFalse(panel.isVisible)
                checks += 1
            }
        )
        workspace.setUpdater(updater)

        for expectedChecks in 1...2 {
            XCTAssertTrue(workspace.isVisible)
            XCTAssertTrue(panel.isVisible)
            updater.checkForUpdates()
            XCTAssertEqual(checks, expectedChecks)
            XCTAssertTrue(workspace.isSuspendedForExternalWindow)
            workspace.showSettings()
            XCTAssertTrue(panel.isVisible)
        }
        workspace.suspendForExternalWindow()
        updater.checkForUpdates()
        XCTAssertEqual(checks, 3)
    }

    @MainActor
    func testOpeningWorkspaceQuietlyChecksForUpdateInformation() {
        _ = NSApplication.shared
        let workspace = ProgramBoardOverlayController(boardRouteResolver: { .unavailable })
        workspace.setSettingsContentProvider { AnyView(Text("Settings")) }
        defer { workspace.suspendForExternalWindow() }
        var probes = 0
        let updater = RelayUpdaterController(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/tmp/relay-runner"),
            focusUpdateUI: { XCTFail("A quiet probe must not focus update UI") },
            scheduleUpdateUIFocus: { _ in },
            checkForUpdatesOverride: { XCTFail("A quiet probe must not start an interactive check") },
            checkForUpdateInformationOverride: { probes += 1 }
        )
        workspace.setUpdater(updater)
        let drainMainActor = {
            let drained = self.expectation(description: "Workspace open tasks ran")
            Task { @MainActor in drained.fulfill() }
            self.wait(for: [drained], timeout: 2)
        }

        workspace.showSettings()
        drainMainActor()
        XCTAssertTrue(workspace.isVisible)
        XCTAssertEqual(probes, 1)
        workspace.showSettings()
        drainMainActor()
        XCTAssertEqual(probes, 1)

        workspace.suspendForExternalWindow()
        workspace.showSettings()
        drainMainActor()
        XCTAssertTrue(workspace.isVisible)
        XCTAssertEqual(probes, 2)
    }

    @MainActor
    func testAvailableUpdateAppearsOnlyAfterSparkleFindsOneAndClearsWhenCurrent() throws {
        var checks = 0
        let controller = RelayUpdaterController(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/tmp/relay-runner"),
            focusUpdateUI: {},
            scheduleUpdateUIFocus: { _ in },
            checkForUpdatesOverride: { checks += 1 }
        )
        let workspace = WorkspaceViewModel()
        workspace.updater = controller
        let sparkle = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        ).updater
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "enclosure": [
                "url": "https://example.com/RelayRunner.zip",
                "sparkle:version": "999",
                "sparkle:shortVersionString": "9.9.9",
            ],
        ]))

        XCTAssertNil(workspace.updater?.availableVersion)
        controller.updater(sparkle, didFindValidUpdate: item)
        XCTAssertEqual(workspace.updater?.availableVersion, "9.9.9")
        workspace.updater?.checkForUpdates()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(workspace.selectedTab, .work)
        controller.updater(sparkle, didAbortWithError: NSError(domain: NSURLErrorDomain, code: -1009))
        XCTAssertEqual(workspace.updater?.availableVersion, "9.9.9")
        controller.updaterDidNotFindUpdate(sparkle)
        XCTAssertNil(workspace.updater?.availableVersion)
    }

    func testUpdaterStartsForInstalledRelayRunnerApp() {
        XCTAssertTrue(RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        ))
    }

    func testUpdaterDoesNotStartForInstallerContext() {
        let context = RelayInstallerContext(
            sourceBundleURL: URL(
                fileURLWithPath: "/Volumes/Relay Runner Install/Relay Runner.app",
                isDirectory: true
            ),
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )

        XCTAssertFalse(RelayUpdaterController.shouldStartAutomatically(
            installerContext: context,
            bundleURL: context.sourceBundleURL
        ))
    }

    func testUpdaterDoesNotStartFromDmgWithoutInstallerContext() {
        XCTAssertFalse(RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: URL(
                fileURLWithPath: "/Volumes/Relay Runner Install/Relay Runner.app",
                isDirectory: true
            )
        ))
    }

    func testUpdaterDoesNotStartFromDownloadsAppBundle() {
        XCTAssertFalse(RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/Users/example/Downloads/Relay Runner.app", isDirectory: true)
        ))
    }

    func testUpdaterDoesNotStartOutsideAppBundle() {
        XCTAssertFalse(RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/tmp/relay-runner", isDirectory: false)
        ))
    }

    @MainActor
    func testCheckForUpdatesFocusesUpdateUIBeforeAndAfterSparkleCheck() {
        var events: [String] = []
        let controller = RelayUpdaterController(
            installerContext: RelayInstallerContext(
                sourceBundleURL: URL(fileURLWithPath: "/tmp/Relay Runner.app", isDirectory: true),
                applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            focusUpdateUI: {
                events.append("focus")
            },
            scheduleUpdateUIFocus: { focus in
                events.append("schedule-focus")
                focus()
            },
            checkForUpdatesOverride: {
                events.append("check")
            }
        )

        controller.checkForUpdates()

        XCTAssertEqual(events, ["focus", "check", "schedule-focus", "focus"])
    }

    @MainActor
    func testSparkleRelaunchHookStopsBundledServicesOnce() {
        var prepareCount = 0
        let controller = RelayUpdaterController(
            installerContext: RelayInstallerContext(
                sourceBundleURL: URL(fileURLWithPath: "/tmp/Relay Runner.app", isDirectory: true),
                applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            prepareForRelaunch: {
                prepareCount += 1
            }
        )

        controller.prepareForSparkleRelaunch()
        controller.prepareForSparkleRelaunch()

        XCTAssertEqual(prepareCount, 1)
    }

    @MainActor
    func testPostponedRelaunchPreparesBeforeContinuingInstall() {
        var events: [String] = []
        let controller = RelayUpdaterController(
            installerContext: RelayInstallerContext(
                sourceBundleURL: URL(fileURLWithPath: "/tmp/Relay Runner.app", isDirectory: true),
                applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            prepareForRelaunch: {
                events.append("prepare")
            },
            scheduleRelaunchContinuation: { continueRelaunch in
                events.append("schedule-continue")
                continueRelaunch()
            }
        )

        let didPostpone = controller.postponeRelaunchUntilPrepared {
            events.append("continue")
        }

        XCTAssertTrue(didPostpone)
        XCTAssertEqual(events, ["prepare", "schedule-continue", "continue"])
    }

    func testServiceLifecycleMessageDocumentsActiveWorkerDeferral() {
        XCTAssertEqual(
            AppState.serviceLifecycleMessage(for: .deferredActiveRuns),
            "Bundled service refresh deferred until active orchestrator workers finish. "
                + "Quit and reopen Relay Runner after they finish."
        )
    }

    func testServiceLifecycleMessageSuppressesSuccessfulRefresh() {
        XCTAssertNil(AppState.serviceLifecycleMessage(for: .restarted))
    }

    func testServiceLifecycleMessageSuppressesUninstalledOrchestratorRefresh() {
        XCTAssertNil(AppState.serviceLifecycleMessage(for: .notInstalled))
    }
}
