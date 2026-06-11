import Foundation
import Sparkle

@MainActor
final class RelayUpdaterController {
    private let standardUpdaterController: SPUStandardUpdaterController?

    init(
        installerContext: RelayInstallerContext?,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        guard Self.shouldStartAutomatically(
            installerContext: installerContext,
            bundleURL: bundleURL
        ) else {
            standardUpdaterController = nil
            return
        }

        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
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

    nonisolated static func shouldStartAutomatically(
        installerContext: RelayInstallerContext?,
        bundleURL: URL
    ) -> Bool {
        installerContext == nil && bundleURL.pathExtension == "app"
    }
}
