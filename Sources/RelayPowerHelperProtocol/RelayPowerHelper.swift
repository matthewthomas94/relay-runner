import Foundation

/// The only operations Relay Runner's root power helper performs. None takes a
/// command, path, pid, or power key: each one changes the system-wide sleep
/// override in a single fixed way.
@objc public protocol RelayPowerHelperProtocol {
    /// Replies with `RelayPowerHelperIdentity.protocolVersion`.
    func hello(reply: @escaping (Int) -> Void)
    /// Disables system sleep while this connection holds it. Replies with a `RelayPowerHelperReply`.
    func holdSleepOverride(reply: @escaping (Int) -> Void)
    /// Ends this connection's hold. The helper restores sleep it disabled once nothing holds it.
    func releaseSleepOverride(reply: @escaping (Int) -> Void)
    /// Re-enables sleep left disabled by an earlier Relay Runner session. Refused while held.
    func restoreSleep(reply: @escaping (Int) -> Void)
}

public enum RelayPowerHelperReply: Int {
    /// The helper disabled sleep, or it already held the override, for this connection.
    case held = 1
    /// Another app had already disabled sleep; the helper left that setting alone.
    case heldElsewhere
    case released
    /// A Relay Runner connection still holds the override.
    case busy
    case failed
}

/// Identifiers shared by the app, its helper, launchd metadata, and the build.
/// `services/app_signing.py` checks the packaged plist and signatures against them.
public enum RelayPowerHelperIdentity {
    public static let label = "com.relayrunner.app.power-helper"
    public static let machServiceName = label
    public static let plistName = "\(label).plist"
    public static let executableName = "relay-power-helper"
    public static let appIdentifier = "com.relayrunner.app"
    public static let teamIdentifier = "QK9K4AQRNH"
    public static let protocolVersion = 1

    /// Relay Runner's Developer ID designated requirement, the same one TCC records.
    public static let appRequirement = developerIDRequirement(identifier: appIdentifier)
    /// The client verifies it is talking to Relay's own helper before trusting a reply.
    public static let helperRequirement = developerIDRequirement(identifier: label)

    static func developerIDRequirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public enum RelayPowerSettings {
    public static let pmset = "/usr/bin/pmset"
    public static let readArguments = ["-g"]
    public static func setArguments(sleepDisabled: Bool) -> [String] {
        ["-a", "disablesleep", sleepDisabled ? "1" : "0"]
    }

    /// `pmset -g`'s system-wide SleepDisabled value; nil when it can't be read. pmset prints
    /// SleepDisabled only once a system-wide power setting has been saved, so on a Mac that
    /// never disabled sleep a report with a settings header but no such line means false.
    public static func sleepDisabled(inPmsetOutput output: String) -> Bool? {
        var isReport = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("System-wide power settings:") || line.hasPrefix("Currently in use:") {
                isReport = true
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.first == "SleepDisabled", fields.count >= 2 else { continue }
            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return isReport ? false : nil
    }
}

/// Runs a fixed child process with a deadline, so no power read or change can hang its caller.
public enum RelayPowerCommandRunner {
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32?, output: String) {
        let process = Process()
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return (nil, "") }
        try? pipe.fileHandleForWriting.close()
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        let output = drain(pipe.fileHandleForReading.fileDescriptor)
        return (timedOut || process.isRunning ? nil : process.terminationStatus, output)
    }

    /// Never blocks on a descendant that might still hold the pipe open.
    private static func drain(_ descriptor: Int32) -> String {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
