import Foundation

extension PermissionKind {
    var opensSystemSettingsDuringSetup: Bool {
        self != .microphone
    }

    var requiresAutomaticRelaunchGuard: Bool {
        self == .inputMonitoring || self == .screenRecording
    }
}

final class PermissionRelaunchGuard {
    typealias WatcherLauncher = (_ processID: Int32, _ appBundleURL: URL, _ timeoutSeconds: Int) -> AnyObject?
    typealias Log = (String) -> Void

    static let timeoutSeconds = 300
    static let watcherScript = """
    current_pid="$1"
    app_path="$2"
    remaining="$3"
    open_command="$4"
    while [ "$remaining" -gt 0 ]; do
        if ! /bin/kill -0 "$current_pid" 2>/dev/null; then
            /bin/sleep 1
            "$open_command" "$app_path"
            exit $?
        fi
        /bin/sleep 1
        remaining=$((remaining - 1))
    done
    exit 0
    """

    private let currentProcessID: () -> Int32
    private let currentBundleURL: () -> URL
    private let launchWatcher: WatcherLauncher
    private let log: Log
    private var watcherToken: AnyObject?

    init(
        currentProcessID: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        currentBundleURL: @escaping () -> URL = { Bundle.main.bundleURL },
        launchWatcher: @escaping WatcherLauncher = PermissionRelaunchGuard.launchWatcher,
        log: @escaping Log = { message in NSLog("[RelayRunner] %@", message) }
    ) {
        self.currentProcessID = currentProcessID
        self.currentBundleURL = currentBundleURL
        self.launchWatcher = launchWatcher
        self.log = log
    }

    @discardableResult
    func armIfNeeded(for permission: PermissionKind) -> Bool {
        guard permission.requiresAutomaticRelaunchGuard else { return false }
        if watcherToken != nil { return true }

        let appBundleURL = currentBundleURL().standardizedFileURL.resolvingSymlinksInPath()
        guard appBundleURL.isFileURL,
              appBundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            log("Permission relaunch watcher skipped because the current process is not running from an app bundle.")
            return false
        }

        guard let watcherToken = launchWatcher(currentProcessID(), appBundleURL, Self.timeoutSeconds) else {
            log("Permission relaunch watcher could not be started.")
            return false
        }
        self.watcherToken = watcherToken
        log("Permission relaunch watcher armed for \(permission.displayName).")
        return true
    }

    var isArmed: Bool {
        watcherToken != nil
    }

    static func watcherArguments(
        processID: Int32,
        appBundleURL: URL,
        timeoutSeconds: Int,
        openExecutablePath: String = "/usr/bin/open"
    ) -> [String] {
        [
            "-c",
            watcherScript,
            "relay-permission-relaunch",
            String(processID),
            appBundleURL.path,
            String(timeoutSeconds),
            openExecutablePath,
        ]
    }

    private static func launchWatcher(
        processID: Int32,
        appBundleURL: URL,
        timeoutSeconds: Int
    ) -> AnyObject? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = watcherArguments(
            processID: processID,
            appBundleURL: appBundleURL,
            timeoutSeconds: timeoutSeconds
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return process
        } catch {
            NSLog("[RelayRunner] Permission relaunch watcher failed: %@", error.localizedDescription)
            return nil
        }
    }
}
