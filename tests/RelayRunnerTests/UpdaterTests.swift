import XCTest
@testable import relay_runner

final class UpdaterTests: XCTestCase {
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
    func testSparkleRelaunchHookStopsBundledServices() {
        var didPrepare = false
        let controller = RelayUpdaterController(
            installerContext: RelayInstallerContext(
                sourceBundleURL: URL(fileURLWithPath: "/tmp/Relay Runner.app", isDirectory: true),
                applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            prepareForRelaunch: {
                didPrepare = true
            }
        )

        controller.prepareForSparkleRelaunch()

        XCTAssertTrue(didPrepare)
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
