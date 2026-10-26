import Foundation
import RelayPowerHelperProtocol

/// Reads and sets the system-wide sleep override with fixed `pmset` commands.
struct PowerHelperPower {
    var sleepDisabled: () -> Bool?
    var setSleepDisabled: (Bool) -> Bool

    static let readTimeout: TimeInterval = 5
    static let changeTimeout: TimeInterval = 10

    static let live = PowerHelperPower(
        sleepDisabled: {
            let result = RelayPowerCommandRunner.run(RelayPowerSettings.pmset, RelayPowerSettings.readArguments,
                                                     timeout: readTimeout)
            guard result.status == 0 else { return nil }
            return RelayPowerSettings.sleepDisabled(inPmsetOutput: result.output)
        },
        setSleepDisabled: { disabled in
            RelayPowerCommandRunner.run(RelayPowerSettings.pmset, RelayPowerSettings.setArguments(sleepDisabled: disabled),
                                        timeout: changeTimeout).status == 0
        }
    )
}

/// A root-owned record that the helper disabled sleep. It is written before the change and
/// removed after a confirmed restore, so a helper crash or power loss is undone the next
/// time launchd starts the helper, including at boot.
struct PowerHelperOwnershipRecord {
    let directory: URL
    var url: URL { directory.appendingPathComponent("sleep-override") }

    static let live = PowerHelperOwnershipRecord(
        directory: URL(fileURLWithPath: "/Library/Application Support/\(RelayPowerHelperIdentity.label)", isDirectory: true)
    )

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Refuses a directory another account could write to or swap for a link.
    func write() -> Bool {
        _ = mkdir(directory.path, 0o755)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { return false }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    func clear() { _ = unlink(url.path) }
}

/// Root-side Keep Awake ownership. Every call runs on the service's serial queue.
final class PowerHelperCore {
    private let power: PowerHelperPower
    private let record: PowerHelperOwnershipRecord
    private var holders = Set<ObjectIdentifier>()
    /// The helper disabled sleep and owes the restore.
    private(set) var ownsOverride: Bool

    var isHeld: Bool { !holders.isEmpty }

    init(power: PowerHelperPower, record: PowerHelperOwnershipRecord) {
        self.power = power
        self.record = record
        ownsOverride = record.exists
    }

    func hold(for client: ObjectIdentifier) -> RelayPowerHelperReply {
        guard let disabled = power.sleepDisabled() else { return .failed }
        // Another app's override: never recorded as ours, so no release ever clears it.
        if disabled, !ownsOverride { return .heldElsewhere }
        if !disabled {
            guard record.write() else { return .failed }
            ownsOverride = true
            guard power.setSleepDisabled(true), power.sleepDisabled() == true else {
                if holders.isEmpty { _ = restore() }
                return .failed
            }
        }
        holders.insert(client)
        return .held
    }

    /// Restores sleep the helper disabled once no connection holds it.
    func release(for client: ObjectIdentifier) -> RelayPowerHelperReply {
        holders.remove(client)
        guard holders.isEmpty, ownsOverride else { return .released }
        return restore() ? .released : .failed
    }

    /// Relay Runner asks only when its own recovery record survived an earlier session.
    func restoreLeftover() -> RelayPowerHelperReply {
        guard holders.isEmpty else { return .busy }
        return restore() ? .released : .failed
    }

    /// Restores an override nothing holds, such as one left by an earlier helper process.
    func restoreIfUnheld() -> Bool {
        guard ownsOverride, holders.isEmpty else { return true }
        return restore()
    }

    private func restore() -> Bool {
        guard power.setSleepDisabled(false), power.sleepDisabled() == false else { return false }
        ownsOverride = false
        record.clear()
        return true
    }
}

/// Accepts only Relay Runner's own signed app, serializes every change, and ends a
/// connection's hold when it disconnects, so sleep stays disabled no longer than the app runs.
final class PowerHelperService: NSObject, NSXPCListenerDelegate {
    static let maxConnections = 4
    static let idleExitDelay: TimeInterval = 10
    static let restoreRetryInterval: TimeInterval = 5

    enum Operation { case hold, release, restore }

    let queue = DispatchQueue(label: "\(RelayPowerHelperIdentity.label).state")
    private let core: PowerHelperCore
    private let requirement: String
    private let exit: () -> Void
    private let log: (String) -> Void
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var idleGeneration = 0

    init(core: PowerHelperCore, requirement: String = RelayPowerHelperIdentity.appRequirement,
         exit: @escaping () -> Void, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.core = core
        self.requirement = requirement
        self.exit = exit
        self.log = log
    }

    /// Launch: no connection exists yet, so undo any override an earlier process left behind.
    func start() {
        queue.async { [self] in
            if !core.restoreIfUnheld() {
                log("Could not restore a sleep override left by an earlier helper process")
                retryRestore()
            }
            scheduleIdleExit()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = ObjectIdentifier(connection)
        let accepted: Bool = queue.sync {
            guard connections.count < Self.maxConnections else { return false }
            connections[client] = connection
            idleGeneration += 1
            return true
        }
        guard accepted else {
            log("Rejected a connection over the limit")
            return false
        }
        // Checked against each message's audit token, so a reused pid can't impersonate the app.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: RelayPowerHelperProtocol.self)
        connection.exportedObject = PowerHelperSession(service: self, client: client)
        connection.invalidationHandler = { [weak self] in self?.ended(client) }
        connection.resume()
        return true
    }

    func perform(_ operation: Operation, for client: ObjectIdentifier, reply: @escaping (Int) -> Void) {
        queue.async { [self] in
            guard connections[client] != nil else { return reply(RelayPowerHelperReply.failed.rawValue) }
            let result: RelayPowerHelperReply
            switch operation {
            case .hold: result = core.hold(for: client)
            case .release: result = core.release(for: client)
            case .restore: result = core.restoreLeftover()
            }
            log("Keep Awake \(operation) -> \(result)")
            reply(result.rawValue)
            if result == .failed, !core.isHeld, core.ownsOverride { retryRestore() }
        }
    }

    private func ended(_ client: ObjectIdentifier) {
        queue.async { [self] in
            guard connections.removeValue(forKey: client) != nil else { return }
            if core.release(for: client) == .failed {
                log("Could not restore sleep after Relay Runner disconnected")
                retryRestore()
            }
            scheduleIdleExit()
        }
    }

    private func retryRestore(attempt: Int = 1) {
        queue.asyncAfter(deadline: .now() + Self.restoreRetryInterval * Double(min(attempt, 12))) { [self] in
            guard !core.isHeld, core.ownsOverride else { return }
            if core.restoreIfUnheld() { scheduleIdleExit() } else { retryRestore(attempt: attempt + 1) }
        }
    }

    /// launchd starts the helper again on the next request, so it never idles in the background.
    private func scheduleIdleExit() {
        idleGeneration += 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + Self.idleExitDelay) { [self] in
            guard generation == idleGeneration, connections.isEmpty, !core.ownsOverride else { return }
            exit()
        }
    }
}

/// One connection's exported object. Every request is forwarded with that connection's identity.
final class PowerHelperSession: NSObject, RelayPowerHelperProtocol {
    private weak var service: PowerHelperService?
    private let client: ObjectIdentifier

    init(service: PowerHelperService, client: ObjectIdentifier) {
        self.service = service
        self.client = client
    }

    func hello(reply: @escaping (Int) -> Void) { reply(RelayPowerHelperIdentity.protocolVersion) }

    func holdSleepOverride(reply: @escaping (Int) -> Void) { forward(.hold, reply) }

    func releaseSleepOverride(reply: @escaping (Int) -> Void) { forward(.release, reply) }

    func restoreSleep(reply: @escaping (Int) -> Void) { forward(.restore, reply) }

    private func forward(_ operation: PowerHelperService.Operation, _ reply: @escaping (Int) -> Void) {
        guard let service else { return reply(RelayPowerHelperReply.failed.rawValue) }
        service.perform(operation, for: client, reply: reply)
    }
}
