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

    func testUpdaterDoesNotStartOutsideAppBundle() {
        XCTAssertFalse(RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: URL(fileURLWithPath: "/tmp/relay-runner", isDirectory: false)
        ))
    }
}
