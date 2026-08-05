import Foundation
import XCTest
@testable import relay_runner

final class PermissionRelaunchGuardTests: XCTestCase {
    func testPermissionHandoffPolicySeparatesExternalAndRelaunchSensitiveKinds() {
        XCTAssertFalse(PermissionKind.microphone.opensSystemSettingsDuringSetup)
        XCTAssertTrue(PermissionKind.accessibility.opensSystemSettingsDuringSetup)
        XCTAssertTrue(PermissionKind.inputMonitoring.opensSystemSettingsDuringSetup)
        XCTAssertTrue(PermissionKind.screenRecording.opensSystemSettingsDuringSetup)

        XCTAssertFalse(PermissionKind.microphone.requiresAutomaticRelaunchGuard)
        XCTAssertFalse(PermissionKind.accessibility.requiresAutomaticRelaunchGuard)
        XCTAssertTrue(PermissionKind.inputMonitoring.requiresAutomaticRelaunchGuard)
        XCTAssertTrue(PermissionKind.screenRecording.requiresAutomaticRelaunchGuard)
    }

    func testGuardArmsOneWatcherForRepeatedSensitivePermissionRequests() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        var launches: [(Int32, URL, Int)] = []
        let guardController = PermissionRelaunchGuard(
            currentProcessID: { 4242 },
            currentBundleURL: { bundleURL },
            launchWatcher: { processID, appBundleURL, timeoutSeconds in
                launches.append((processID, appBundleURL, timeoutSeconds))
                return NSObject()
            },
            log: { _ in }
        )

        XCTAssertTrue(guardController.armIfNeeded(for: .screenRecording))
        XCTAssertTrue(guardController.armIfNeeded(for: .inputMonitoring))

        XCTAssertTrue(guardController.isArmed)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.0, 4242)
        XCTAssertEqual(launches.first?.1, bundleURL)
        XCTAssertEqual(launches.first?.2, PermissionRelaunchGuard.timeoutSeconds)
    }

    func testGuardSkipsLivePermissionAndCanRetryAWatcherLaunchFailure() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        var launchCount = 0
        let guardController = PermissionRelaunchGuard(
            currentBundleURL: { bundleURL },
            launchWatcher: { _, _, _ in
                launchCount += 1
                return launchCount > 1 ? NSObject() : nil
            },
            log: { _ in }
        )

        XCTAssertFalse(guardController.armIfNeeded(for: .accessibility))
        XCTAssertFalse(guardController.armIfNeeded(for: .screenRecording))
        XCTAssertTrue(guardController.armIfNeeded(for: .screenRecording))

        XCTAssertEqual(launchCount, 2)
        XCTAssertTrue(guardController.isArmed)
    }

    func testWatcherUsesBoundedPollingAndPositionalBundleArguments() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Relay Runner.app", isDirectory: true)
        let arguments = PermissionRelaunchGuard.watcherArguments(
            processID: 4242,
            appBundleURL: bundleURL,
            timeoutSeconds: 30
        )

        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(arguments[2], "relay-permission-relaunch")
        XCTAssertEqual(arguments[3], "4242")
        XCTAssertEqual(arguments[4], bundleURL.path)
        XCTAssertEqual(arguments[5], "30")
        XCTAssertEqual(arguments[6], "/usr/bin/open")
        XCTAssertTrue(arguments[1].contains("/bin/kill -0 \"$current_pid\""))
        XCTAssertTrue(arguments[1].contains("remaining=$((remaining - 1))"))
        XCTAssertTrue(arguments[1].contains("\"$open_command\" \"$app_path\""))
        XCTAssertFalse(arguments[1].contains(bundleURL.path))
    }

    func testWatcherExpiresWithoutOpeningWhileWatchedProcessRemainsAlive() throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-permission-live-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = PermissionRelaunchGuard.watcherArguments(
            processID: ProcessInfo.processInfo.processIdentifier,
            appBundleURL: sentinel,
            timeoutSeconds: 1,
            openExecutablePath: "/usr/bin/touch"
        )

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testWatcherInvokesOpenCommandAfterWatchedProcessExits() throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-permission-exited-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = PermissionRelaunchGuard.watcherArguments(
            processID: Int32.max,
            appBundleURL: sentinel,
            timeoutSeconds: 2,
            openExecutablePath: "/usr/bin/touch"
        )

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
