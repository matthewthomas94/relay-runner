import Foundation
import RelayPowerHelperProtocol
import ServiceManagement

/// The SMAppService registration of Relay Runner's power helper, a launchd daemon
/// packaged in Contents/Library/LaunchDaemons. Injected so tests never register it.
struct KeepAwakeHelperRegistration {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    /// Waits, bounded, for launchd to remove the job.
    var unregister: () -> Void
    var openSystemSettings: () -> Void
    /// Whether this copy of the app carries the helper's launchd plist and the executable it names.
    var isPackaged: () -> Bool

    static let unregisterTimeout: TimeInterval = 5

    static func live() -> KeepAwakeHelperRegistration {
        let service = SMAppService.daemon(plistName: RelayPowerHelperIdentity.plistName)
        return KeepAwakeHelperRegistration(
            status: { service.status },
            register: { try service.register() },
            unregister: {
                let done = DispatchSemaphore(value: 0)
                service.unregister { _ in done.signal() }
                _ = done.wait(timeout: .now() + unregisterTimeout)
            },
            openSystemSettings: { DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() } },
            isPackaged: { isPackaged(in: Bundle.main.bundleURL) }
        )
    }

    /// SMAppService reports a daemon macOS has no record of yet as notFound, the same as one
    /// absent from the bundle, so the bundle itself settles which it is.
    static func isPackaged(in bundle: URL) -> Bool {
        let plist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(RelayPowerHelperIdentity.plistName)")
        guard let job = NSDictionary(contentsOf: plist) as? [String: Any],
              job["Label"] as? String == RelayPowerHelperIdentity.label,
              job["BundleProgram"] as? String == bundleProgram else { return false }
        return FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent(bundleProgram).path)
    }

    static let bundleProgram = "Contents/MacOS/\(RelayPowerHelperIdentity.executableName)"
}

/// Relay Runner's side of the power helper. macOS asks the user to allow the helper once,
/// in System Settings; later toggles and relaunches reuse that approval without a prompt
/// until it is turned off there. Every request is fixed and bounded, and replies count only
/// from a peer that satisfies the helper's Developer ID requirement.
final class KeepAwakePowerHelper {
    static let replyTimeout: TimeInterval = 15
    static let helloAttempts = 3
    static let helloRetryInterval: TimeInterval = 0.3
    static let reregisterDelay: TimeInterval = 0.5
    /// Status checks a newly allowed helper gets to start answering before it counts as not responding.
    static let startGraceChecks = 10

    static let approvalPlace = "System Settings → General → Login Items"
    static let missingMessage = "Keep Awake's power helper is missing from this copy of Relay Runner. Reinstall Relay Runner to use Keep Awake."
    static func rejectedMessage(_ detail: String) -> String {
        "macOS didn't accept Keep Awake's power helper (\(detail)). It needs a copy of Relay Runner signed by its developer; reinstall Relay Runner to use Keep Awake."
    }
    static let notRespondingMessage = "Keep Awake's power helper isn't responding. Turn Relay Runner off and on again in \(approvalPlace), then try again."
    static let quittingMessage = "Relay Runner is quitting."

    private let registration: KeepAwakeHelperRegistration
    private let makeConnection: () -> NSXPCConnection
    private let replyTimeout: TimeInterval
    private let pause: (TimeInterval) -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private weak var verifiedConnection: NSXPCConnection?
    private var closed = false
    private var repaired = false
    /// This launch saw the helper before the user allowed it.
    private var awaitedApproval = false
    private var startChecks = 0

    init(
        registration: KeepAwakeHelperRegistration = .live(),
        makeConnection: @escaping () -> NSXPCConnection = KeepAwakePowerHelper.systemConnection,
        replyTimeout: TimeInterval = KeepAwakePowerHelper.replyTimeout,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        log: @escaping (String) -> Void = { NSLog("[RelayRunner] %@", $0) }
    ) {
        self.registration = registration
        self.makeConnection = makeConnection
        self.replyTimeout = replyTimeout
        self.pause = pause
        self.log = log
    }

    static func systemConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: RelayPowerHelperIdentity.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(RelayPowerHelperIdentity.helperRequirement)
        return connection
    }

    /// Never prompts. A registration that stops answering, such as one an earlier copy of
    /// the app made, is re-registered once per launch. One the user has only just allowed
    /// is given time to start instead, so a slow first launch never forces a second approval.
    func status() -> KeepAwakeSystem.Helper {
        let current = registration.status()
        guard current == .enabled else {
            lock.lock()
            awaitedApproval = true
            lock.unlock()
            return helper(for: current)
        }
        if hello() { return .ready }
        lock.lock()
        let justAllowed = awaitedApproval
        if justAllowed { startChecks += 1 }
        let starting = justAllowed && startChecks < Self.startGraceChecks
        let mayRepair = !repaired && !closed && !justAllowed
        if mayRepair { repaired = true }
        lock.unlock()
        if starting { return .needsApproval }
        guard mayRepair else { return .unavailable(Self.notRespondingMessage) }
        log("Keep Awake power helper didn't answer; registering it again")
        dropConnection()
        registration.unregister()
        pause(Self.reregisterDelay)
        do { try registration.register() } catch { log("Keep Awake power helper registration: \(Self.describe(error))") }
        let repairedStatus = registration.status()
        guard repairedStatus == .enabled else { return helper(for: repairedStatus) }
        return hello() ? .ready : .unavailable(Self.notRespondingMessage)
    }

    /// Registers the helper if needed and opens System Settings when macOS still needs the user's approval.
    func requestApproval() -> KeepAwakeSystem.Helper {
        guard !isClosed else { return .unavailable(Self.quittingMessage) }
        let before = registration.status()
        var failure: String?
        // A helper macOS has never registered reports notFound as well as notRegistered.
        if before == .notRegistered || before == .notFound {
            guard registration.isPackaged() else {
                log("Keep Awake power helper isn't packaged in this copy of Relay Runner")
                return .unavailable(Self.missingMessage)
            }
            do { try registration.register() } catch { failure = Self.describe(error) }
        }
        let current = registration.status()
        if current != before || failure != nil {
            log("Keep Awake power helper registration: \(Self.name(before)) → \(Self.name(current))"
                + (failure.map { ", \($0)" } ?? ""))
        }
        switch current {
        case .enabled:
            return hello() ? .ready : .unavailable(Self.notRespondingMessage)
        case .requiresApproval:
            registration.openSystemSettings()
            return .needsApproval
        default:
            return .unavailable(Self.rejectedMessage(failure ?? Self.name(current)))
        }
    }

    private func helper(for status: SMAppService.Status) -> KeepAwakeSystem.Helper {
        switch status {
        case .enabled: return .ready
        case .requiresApproval, .notRegistered: return .needsApproval
        case .notFound: return registration.isPackaged() ? .needsApproval : .unavailable(Self.missingMessage)
        @unknown default: return .unavailable(Self.missingMessage)
        }
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "status \(status.rawValue)"
        }
    }

    // MARK: Requests

    func hold() -> KeepAwakeSystem.Hold {
        switch change({ $0.holdSleepOverride(reply: $1) }).flatMap(RelayPowerHelperReply.init(rawValue:)) {
        case .held: return .held
        case .heldElsewhere: return .heldElsewhere
        default: return .failed
        }
    }

    /// Holding nothing afterwards, the connection is dropped so the helper can exit when idle.
    func release() -> Bool {
        defer { dropConnection() }
        return change({ $0.releaseSleepOverride(reply: $1) }) == RelayPowerHelperReply.released.rawValue
    }

    func restore() -> Bool {
        defer { dropConnection() }
        return change({ $0.restoreSleep(reply: $1) }) == RelayPowerHelperReply.released.rawValue
    }

    /// Quit: refuses new requests and ends the connection, which ends this app's hold.
    func close() {
        lock.lock()
        closed = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.invalidate()
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// A reply arrives only from a peer that satisfies the helper requirement, so a
    /// connection that answered hello is the helper's own.
    private func hello() -> Bool {
        for attempt in 1...Self.helloAttempts {
            if let result = call({ $0.hello(reply: $1) }), result.value == RelayPowerHelperIdentity.protocolVersion {
                lock.lock()
                if connection === result.connection { verifiedConnection = result.connection }
                lock.unlock()
                return true
            }
            if attempt < Self.helloAttempts { pause(Self.helloRetryInterval) }
        }
        return false
    }

    /// The requirement filters only replies, so a change is sent only on a connection
    /// that has already proved it reaches Relay's helper.
    private func change(_ send: (RelayPowerHelperProtocol, @escaping (Int) -> Void) -> Void) -> Int? {
        lock.lock()
        let verified = connection != nil && connection === verifiedConnection
        lock.unlock()
        guard verified || hello() else { return nil }
        return call(send, verifiedOnly: true)?.value
    }

    /// Sends one fixed request and waits, bounded, for its reply. A timeout drops the
    /// connection, which ends any hold it had, so a stuck helper can't keep sleep off.
    private func call(_ send: (RelayPowerHelperProtocol, @escaping (Int) -> Void) -> Void,
                      verifiedOnly: Bool = false) -> (value: Int?, connection: NSXPCConnection)? {
        let reply = KeepAwakeHelperReply()
        lock.lock()
        guard !closed, !verifiedOnly || (connection != nil && connection === verifiedConnection) else {
            lock.unlock()
            return nil
        }
        let connection = currentConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(nil) }
        guard let helper = proxy as? RelayPowerHelperProtocol else {
            lock.unlock()
            return nil
        }
        // Sent under the lock, so a request never follows quit's close on the same connection.
        send(helper) { reply.finish($0) }
        lock.unlock()
        switch reply.wait(timeout: replyTimeout) {
        case .some(let value): return (value, connection)
        case .none:
            dropConnection(connection)
            return nil
        }
    }

    /// Call with `lock` held.
    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: RelayPowerHelperProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.dropConnection(connection, invalidate: false)
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func dropConnection(_ expected: NSXPCConnection? = nil, invalidate: Bool = true) {
        lock.lock()
        let current = connection
        if expected == nil || current === expected { connection = nil }
        lock.unlock()
        if invalidate, expected == nil || current === expected { current?.invalidate() }
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

/// One request's reply. The error handler and the reply block may both fire; the first wins.
private final class KeepAwakeHelperReply {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var value: Int?

    func finish(_ value: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        self.value = value
        done.signal()
    }

    /// nil on timeout; `.some(nil)` when the connection reported an error instead of a reply.
    func wait(timeout: TimeInterval) -> Int?? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return .some(value)
    }
}
