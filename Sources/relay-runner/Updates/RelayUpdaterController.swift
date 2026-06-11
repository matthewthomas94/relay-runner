import Foundation
import Sparkle

extension Notification.Name {
    static let relayRunnerWillRelaunchForUpdate = Notification.Name("relayRunnerWillRelaunchForUpdate")
}

@MainActor
final class RelayUpdaterController: NSObject, SPUUpdaterDelegate {
    private var standardUpdaterController: SPUStandardUpdaterController?
    private let prepareForRelaunch: () -> Void

    init(
        installerContext: RelayInstallerContext?,
        bundleURL: URL = Bundle.main.bundleURL,
        prepareForRelaunch: @escaping () -> Void = {}
    ) {
        self.prepareForRelaunch = prepareForRelaunch
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
        guard let standardUpdaterController else {
            NSLog("[RelayRunner] Sparkle updater is unavailable outside the installed app.")
            return
        }
        standardUpdaterController.checkForUpdates(nil)
    }

    func prepareForSparkleRelaunch() {
        NSLog("[RelayRunner] Sparkle will relaunch Relay Runner; stopping bundled services first.")
        NotificationCenter.default.post(name: .relayRunnerWillRelaunchForUpdate, object: nil)
        prepareForRelaunch()
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
}
