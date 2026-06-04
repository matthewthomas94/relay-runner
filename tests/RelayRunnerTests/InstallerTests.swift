import XCTest
@testable import relay_runner

final class InstallerTests: XCTestCase {
    func testInstallerContextOnlyTriggersForDmgOrTranslocatedRelayRunnerApp() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

        XCTAssertTrue(RelayInstallerContext.shouldInstall(
            from: URL(fileURLWithPath: "/Volumes/Relay Runner Install/Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))
        XCTAssertTrue(RelayInstallerContext.shouldInstall(
            from: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))
        XCTAssertFalse(RelayInstallerContext.shouldInstall(
            from: URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))
        XCTAssertFalse(RelayInstallerContext.shouldInstall(
            from: URL(fileURLWithPath: "/Users/example/Downloads/Relay Runner.app", isDirectory: true),
            applicationsURL: applications
        ))
        XCTAssertFalse(RelayInstallerContext.shouldInstall(
            from: URL(fileURLWithPath: "/Volumes/Install Relay Runner/Other.app", isDirectory: true),
            applicationsURL: applications
        ))
    }

    func testInstallRefreshesExistingBundleInApplicationsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayInstallerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Relay Runner.app", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent("Relay Runner.app", isDirectory: true)
        try writeBundle(source, marker: "new")
        try writeBundle(destination, marker: "old")

        var progressFractions: [Double] = []
        try RelayBundleInstaller.install(from: source, to: destination) { progress in
            progressFractions.append(progress.fractionCompleted)
        }

        let marker = try String(
            contentsOf: destination.appendingPathComponent("Contents/Resources/marker.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(marker, "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
            .filter { $0.hasPrefix(".Relay Runner.app.installing-") }
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(progressFractions.last, 1.0)
    }

    func testInstallerKeepsProgressVisibleForAtLeastThreeSeconds() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            RelayInstallerLaunch.remainingDelay(
                startedAt: startedAt,
                now: startedAt.addingTimeInterval(1.2)
            ),
            1.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RelayInstallerLaunch.remainingDelay(
                startedAt: startedAt,
                now: startedAt.addingTimeInterval(3.5)
            ),
            0,
            accuracy: 0.001
        )
    }

    func testInstallerLaunchForcesInstalledBundleInsteadOfRunningInstallerCopy() {
        let configuration = RelayInstallerLaunch.openConfiguration()

        XCTAssertTrue(configuration.activates)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    }

    private func writeBundle(_ url: URL, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: resources.appendingPathComponent("marker.txt"))
        try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("relay-runner"))
    }
}
