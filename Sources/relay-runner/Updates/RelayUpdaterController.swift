import AppKit
import Foundation
import Sparkle

extension Notification.Name {
    static let relayRunnerWillRelaunchForUpdate = Notification.Name("relayRunnerWillRelaunchForUpdate")
}

@MainActor
final class RelayUpdaterController: NSObject, SPUUpdaterDelegate {
    private var standardUpdaterController: SPUStandardUpdaterController?
    private let prepareForRelaunch: () -> Void
    private let focusUpdateUI: @MainActor () -> Void
    private let scheduleUpdateUIFocus: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let checkForUpdatesOverride: (@MainActor () -> Void)?
    private let scheduleRelaunchContinuation: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var didPrepareForRelaunch = false

    init(
        installerContext: RelayInstallerContext?,
        bundleURL: URL = Bundle.main.bundleURL,
        prepareForRelaunch: @escaping () -> Void = {},
        focusUpdateUI: @escaping @MainActor () -> Void = RelayUpdaterController.focusUpdateUI,
        scheduleUpdateUIFocus: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void =
            RelayUpdaterController.scheduleUpdateUIFocus,
        checkForUpdatesOverride: (@MainActor () -> Void)? = nil,
        scheduleRelaunchContinuation: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void =
            RelayUpdaterController.scheduleRelaunchContinuation
    ) {
        self.prepareForRelaunch = prepareForRelaunch
        self.focusUpdateUI = focusUpdateUI
        self.scheduleUpdateUIFocus = scheduleUpdateUIFocus
        self.checkForUpdatesOverride = checkForUpdatesOverride
        self.scheduleRelaunchContinuation = scheduleRelaunchContinuation
        super.init()

        guard Self.shouldStartAutomatically(
            installerContext: installerContext,
            bundleURL: bundleURL
        ) else {
            return
        }

        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard checkForUpdatesOverride != nil || standardUpdaterController != nil else {
            NSLog("[RelayRunner] Sparkle updater is unavailable outside the installed app.")
            return
        }

        focusUpdateUI()
        if let checkForUpdatesOverride {
            checkForUpdatesOverride()
        } else {
            standardUpdaterController?.checkForUpdates(nil)
        }
        scheduleUpdateUIFocus(focusUpdateUI)
    }

    func prepareForSparkleRelaunch() {
        guard !didPrepareForRelaunch else { return }
        didPrepareForRelaunch = true

        NSLog("[RelayRunner] Sparkle will relaunch Relay Runner; stopping bundled services first.")
        NotificationCenter.default.post(name: .relayRunnerWillRelaunchForUpdate, object: nil)
        prepareForRelaunch()
    }

    func postponeRelaunchUntilPrepared(continueRelaunch: @escaping @MainActor () -> Void) -> Bool {
        prepareForSparkleRelaunch()
        scheduleRelaunchContinuation(continueRelaunch)
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeRelaunchUntilPrepared(continueRelaunch: installHandler)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareForSparkleRelaunch()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("[RelayRunner] Sparkle update failed: \(error.localizedDescription)")
    }

    nonisolated static func shouldStartAutomatically(
        installerContext: RelayInstallerContext?,
        bundleURL: URL,
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> Bool {
        guard installerContext == nil,
              bundleURL.pathExtension == "app",
              bundleURL.lastPathComponent == RelayInstallerContext.bundleName else {
            return false
        }
        let installed = applicationsURL
            .appendingPathComponent(RelayInstallerContext.bundleName, isDirectory: true)
        return normalizedPath(bundleURL) == normalizedPath(installed)
    }

    private nonisolated static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func focusUpdateUI() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents {
            window.orderFrontRegardless()
        }
    }

    private static func scheduleUpdateUIFocus(_ focus: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task { @MainActor in
                focus()
            }
        }
    }

    private static func scheduleRelaunchContinuation(_ continueRelaunch: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            Task { @MainActor in
                continueRelaunch()
            }
        }
    }
}
