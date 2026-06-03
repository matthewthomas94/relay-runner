import Foundation

struct RelayInstallerContext {
    static let appName = "Relay Runner"
    static let bundleName = "\(appName).app"

    let sourceBundleURL: URL
    let applicationsURL: URL

    var installedBundleURL: URL {
        applicationsURL.appendingPathComponent(Self.bundleName, isDirectory: true)
    }

    static func current(
        bundleURL: URL = Bundle.main.bundleURL,
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> RelayInstallerContext? {
        shouldInstall(from: bundleURL, applicationsURL: applicationsURL)
            ? RelayInstallerContext(sourceBundleURL: bundleURL, applicationsURL: applicationsURL)
            : nil
    }

    static func shouldInstall(from bundleURL: URL, applicationsURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app",
              bundleURL.lastPathComponent == bundleName else {
            return false
        }

        let source = normalizedPath(bundleURL)
        let installed = normalizedPath(
            applicationsURL.appendingPathComponent(bundleName, isDirectory: true)
        )
        guard source != installed else { return false }

        return source.hasPrefix("/Volumes/") || source.contains("/AppTranslocation/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
