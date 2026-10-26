import Foundation
import RelayPowerHelperProtocol
import Security
import ServiceManagement
import XCTest
@testable import relay_power_helper
@testable import relay_runner

/// An in-memory sleep setting. It is only touched on the helper service's queue.
private final class FakePower {
    var disabled: Bool? = false
    var changes = true
    private(set) var sets: [Bool] = []
    var power: PowerHelperPower {
        PowerHelperPower(
            sleepDisabled: { [self] in disabled },
            setSleepDisabled: { [self] value in
                sets.append(value)
                guard changes else { return false }
                disabled = value
                return true
            }
        )
    }
}

/// This test process's designated requirement, which an in-process peer satisfies.
private func ownRequirement() throws -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw XCTSkip("No code identity") }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw XCTSkip("No static code") }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
        throw XCTSkip("No designated requirement")
    }
    var text: CFString?
    guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw XCTSkip("No requirement text") }
    return text as String
}

/// A helper that accepts a connection and never replies, like one stuck in a command.
private final class StalledHelper: NSObject, NSXPCListenerDelegate, RelayPowerHelperProtocol {
    private var connections: [NSXPCConnection] = []
    private(set) var invalidated = false
    private let lock = NSLock()

    var wasInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RelayPowerHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.lock.lock()
            self?.invalidated = true
            self?.lock.unlock()
        }
        connections.append(connection)
        connection.resume()
        return true
    }

    func hello(reply: @escaping (Int) -> Void) {}
    func holdSleepOverride(reply: @escaping (Int) -> Void) {}
    func releaseSleepOverride(reply: @escaping (Int) -> Void) {}
    func restoreSleep(reply: @escaping (Int) -> Void) {}
}

final class KeepAwakePowerHelperTests: XCTestCase {
    private var directory: URL!
    private var power: FakePower!
    private var listeners: [NSXPCListener] = []
    /// Live objects, so their identities are never reused within a test.
    private let clients = [NSObject(), NSObject()]
    private var client: ObjectIdentifier { ObjectIdentifier(clients[0]) }
    private var otherClient: ObjectIdentifier { ObjectIdentifier(clients[1]) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("power-helper-\(UUID().uuidString)", isDirectory: true)
        power = FakePower()
    }

    override func tearDown() {
        listeners.forEach { $0.invalidate() }
        listeners = []
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var record: PowerHelperOwnershipRecord { PowerHelperOwnershipRecord(directory: directory) }

    private func makeCore() -> PowerHelperCore { PowerHelperCore(power: power.power, record: record) }

    private func makeService(requirement: String) -> PowerHelperService {
        PowerHelperService(core: makeCore(), requirement: requirement, exit: {}, log: { _ in })
    }

    private func listen(_ delegate: NSXPCListenerDelegate) -> NSXPCListener {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        listeners.append(listener)
        return listener
    }

    private func connect(to listener: NSXPCListener, requirement: String? = nil) -> NSXPCConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        return connection
    }

    /// Sends one request on a raw connection; nil when the connection fails instead of replying.
    private func request(_ connection: NSXPCConnection,
                         _ send: (RelayPowerHelperProtocol, @escaping (Int) -> Void) -> Void) -> Int? {
        let done = expectation(description: "reply or error")
        // A failed connection can report its error after a reply, or instead of one.
        done.assertForOverFulfill = false
        var value: Int?
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.fulfill() } as? RelayPowerHelperProtocol
        send(proxy!) { reply in
            value = reply
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return value
    }

    private func rawConnection(to listener: NSXPCListener) -> NSXPCConnection {
        let connection = connect(to: listener)
        connection.remoteObjectInterface = NSXPCInterface(with: RelayPowerHelperProtocol.self)
        connection.resume()
        return connection
    }

    private func waitUntil(_ service: PowerHelperService, _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if service.queue.sync(execute: condition) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Timed out", file: file, line: line)
    }

    // MARK: Root-side ownership

    func testHoldRecordsOwnershipBeforeDisablingAndReleaseRestoresIt() {
        let core = makeCore()
        XCTAssertEqual(core.hold(for: client), .held)
        XCTAssertEqual(power.disabled, true)
        XCTAssertTrue(record.exists, "Ownership is recorded before the change")
        XCTAssertEqual(core.hold(for: client), .held, "Repeated holds are idempotent")
        XCTAssertEqual(power.sets, [true])
        XCTAssertEqual(core.release(for: client), .released)
        XCTAssertEqual(power.disabled, false)
        XCTAssertFalse(record.exists)
        XCTAssertFalse(core.ownsOverride)
    }

    func testAnotherAppsOverrideIsNeverClaimedOrCleared() {
        power.disabled = true
        let core = makeCore()
        XCTAssertEqual(core.hold(for: client), .heldElsewhere)
        XCTAssertFalse(record.exists)
        XCTAssertEqual(core.release(for: client), .released)
        XCTAssertEqual(power.disabled, true)
        XCTAssertTrue(power.sets.isEmpty)
    }

    func testSleepStaysDisabledUntilTheLastHolderReleases() {
        let core = makeCore()
        XCTAssertEqual(core.hold(for: client), .held)
        XCTAssertEqual(core.hold(for: otherClient), .held)
        XCTAssertEqual(core.restoreLeftover(), .busy, "A held override is never restored out from under its holder")
        XCTAssertEqual(core.release(for: client), .released)
        XCTAssertEqual(power.disabled, true)
        XCTAssertEqual(core.release(for: otherClient), .released)
        XCTAssertEqual(power.disabled, false)
    }

    func testOverrideReestablishedAfterAnotherAppClearsIt() {
        let core = makeCore()
        _ = core.hold(for: client)
        power.disabled = false
        XCTAssertEqual(core.hold(for: client), .held)
        XCTAssertEqual(power.disabled, true)
        XCTAssertEqual(power.sets, [true, true])
    }

    func testAnOverrideLeftByAnEarlierProcessIsRestoredAtLaunch() {
        _ = makeCore().hold(for: client)
        XCTAssertTrue(record.exists)
        // The helper crashed or the Mac lost power; launchd starts a fresh process.
        let relaunched = makeCore()
        XCTAssertTrue(relaunched.ownsOverride)
        XCTAssertTrue(relaunched.restoreIfUnheld())
        XCTAssertEqual(power.disabled, false)
        XCTAssertFalse(record.exists)
    }

    func testFailedChangeIsUndoneAndUnreadableSettingsFailClosed() {
        power.changes = false
        let core = makeCore()
        XCTAssertEqual(core.hold(for: client), .failed)
        XCTAssertTrue(core.ownsOverride, "An unconfirmed restore keeps the record")
        power.changes = true
        XCTAssertTrue(core.restoreIfUnheld())
        XCTAssertFalse(record.exists)

        power.disabled = nil
        XCTAssertEqual(core.hold(for: client), .failed)
        XCTAssertFalse(record.exists)
    }

    func testOwnershipRecordRefusesADirectoryOthersCanWrite() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let core = makeCore()
        XCTAssertEqual(core.hold(for: client), .failed)
        XCTAssertTrue(power.sets.isEmpty, "No change without a trustworthy record")

        try FileManager.default.removeItem(at: directory)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("power-helper-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertFalse(record.write(), "A link in place of the directory is refused")
    }

    // MARK: Peer validation and connection leases

    func testServiceRejectsAPeerThatIsNotRelayRunner() {
        let service = makeService(requirement: RelayPowerHelperIdentity.appRequirement)
        let listener = listen(service)
        let connection = rawConnection(to: listener)
        defer { connection.invalidate() }
        XCTAssertNil(request(connection) { $0.hello(reply: $1) }, "An unauthorized client gets no reply")
        XCTAssertNil(request(connection) { $0.holdSleepOverride(reply: $1) })
        XCTAssertTrue(service.queue.sync { power.sets.isEmpty }, "Nothing changes for an unauthorized client")
    }

    func testAuthorizedPeerHoldsUntilItReleasesOrDisconnects() throws {
        let service = makeService(requirement: try ownRequirement())
        let listener = listen(service)
        let connection = rawConnection(to: listener)
        XCTAssertEqual(request(connection) { $0.hello(reply: $1) }, RelayPowerHelperIdentity.protocolVersion)
        XCTAssertEqual(request(connection) { $0.holdSleepOverride(reply: $1) }, RelayPowerHelperReply.held.rawValue)
        XCTAssertEqual(service.queue.sync { power.disabled }, true)
        XCTAssertEqual(request(connection) { $0.releaseSleepOverride(reply: $1) }, RelayPowerHelperReply.released.rawValue)
        XCTAssertEqual(service.queue.sync { power.disabled }, false)

        XCTAssertEqual(request(connection) { $0.holdSleepOverride(reply: $1) }, RelayPowerHelperReply.held.rawValue)
        // The app quit or crashed: its connection goes away without a release.
        connection.invalidate()
        waitUntil(service) { self.power.disabled == false }
        XCTAssertFalse(record.exists)
    }

    func testAnotherConnectionCannotRestoreAnOverrideStillHeld() throws {
        let service = makeService(requirement: try ownRequirement())
        let listener = listen(service)
        let holder = rawConnection(to: listener)
        let other = rawConnection(to: listener)
        defer {
            holder.invalidate()
            other.invalidate()
        }
        XCTAssertEqual(request(holder) { $0.holdSleepOverride(reply: $1) }, RelayPowerHelperReply.held.rawValue)
        XCTAssertEqual(request(other) { $0.restoreSleep(reply: $1) }, RelayPowerHelperReply.busy.rawValue)
        XCTAssertEqual(service.queue.sync { power.disabled }, true)
    }

    func testConnectionsBeyondTheLimitAreRefused() throws {
        let service = makeService(requirement: try ownRequirement())
        let listener = listen(service)
        let connections = (0...PowerHelperService.maxConnections).map { _ in rawConnection(to: listener) }
        defer { connections.forEach { $0.invalidate() } }
        let replies = connections.map { connection in request(connection) { $0.hello(reply: $1) } }
        XCTAssertEqual(replies.compactMap { $0 }.count, PowerHelperService.maxConnections)
        XCTAssertNil(replies.last ?? nil)
    }

    // MARK: App-side client

    private final class FakeRegistration {
        var status: SMAppService.Status = .enabled
        var statusAfterRegister: SMAppService.Status?
        var registerError: Error?
        var packaged = true
        private(set) var registers = 0
        private(set) var unregisters = 0
        private(set) var settingsOpened = 0

        var registration: KeepAwakeHelperRegistration {
            KeepAwakeHelperRegistration(
                status: { [self] in status },
                register: { [self] in
                    registers += 1
                    if let statusAfterRegister { status = statusAfterRegister }
                    if let registerError { throw registerError }
                },
                unregister: { [self] in unregisters += 1 },
                openSystemSettings: { [self] in settingsOpened += 1 },
                isPackaged: { [self] in packaged }
            )
        }
    }

    private func makeClient(_ registration: FakeRegistration, listener: NSXPCListener,
                            helperRequirement: String?, replyTimeout: TimeInterval = 5,
                            log: @escaping (String) -> Void = { _ in }) -> KeepAwakePowerHelper {
        KeepAwakePowerHelper(registration: registration.registration,
                             makeConnection: { self.connect(to: listener, requirement: helperRequirement) },
                             replyTimeout: replyTimeout, pause: { _ in }, log: log)
    }

    func testApprovedHelperIsReadyAndHoldsReleasesAndRestoresThroughFixedRequests() throws {
        let requirement = try ownRequirement()
        let service = makeService(requirement: requirement)
        let registration = FakeRegistration()
        let client = makeClient(registration, listener: listen(service), helperRequirement: requirement)
        XCTAssertEqual(client.status(), .ready)
        XCTAssertEqual(client.hold(), .held)
        XCTAssertEqual(service.queue.sync { power.disabled }, true)
        XCTAssertTrue(client.release())
        XCTAssertEqual(service.queue.sync { power.disabled }, false)
        XCTAssertTrue(client.restore())
        XCTAssertEqual(registration.registers, 0, "An approved helper is never registered again")
        XCTAssertEqual(registration.settingsOpened, 0)
        client.close()
    }

    func testCloseRefusesNewRequestsAndEndsTheHold() throws {
        let requirement = try ownRequirement()
        let service = makeService(requirement: requirement)
        let client = makeClient(FakeRegistration(), listener: listen(service), helperRequirement: requirement)
        XCTAssertEqual(client.hold(), .held)
        client.close()
        waitUntil(service) { self.power.disabled == false }
        XCTAssertEqual(client.hold(), .failed)
        XCTAssertFalse(client.release())
        XCTAssertEqual(client.requestApproval(), .unavailable(KeepAwakePowerHelper.quittingMessage))
        XCTAssertEqual(service.queue.sync { power.sets }, [true, false])
    }

    func testFirstUseRegistersOnceAndOpensTheApprovalInSystemSettings() throws {
        let registration = FakeRegistration()
        registration.status = .notRegistered
        registration.statusAfterRegister = .requiresApproval
        registration.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let client = makeClient(registration, listener: listen(StalledHelper()), helperRequirement: nil)
        XCTAssertEqual(client.status(), .needsApproval, "Checking status never registers or prompts")
        XCTAssertEqual(registration.registers, 0)
        XCTAssertEqual(client.requestApproval(), .needsApproval)
        XCTAssertEqual(registration.registers, 1)
        XCTAssertEqual(registration.settingsOpened, 1)

        // Revoked later in Login Items: reopen the approval, never re-register.
        XCTAssertEqual(client.requestApproval(), .needsApproval)
        XCTAssertEqual(registration.registers, 1)
        XCTAssertEqual(registration.settingsOpened, 2)
    }

    func testNeverRegisteredHelperReportedAsNotFoundIsRegisteredOnFirstUse() throws {
        // macOS reports a packaged daemon it has no record of yet as notFound.
        let registration = FakeRegistration()
        registration.status = .notFound
        registration.statusAfterRegister = .requiresApproval
        registration.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        var logged: [String] = []
        let client = makeClient(registration, listener: listen(StalledHelper()), helperRequirement: nil,
                                log: { logged.append($0) })
        XCTAssertEqual(client.status(), .needsApproval, "Not yet registered, not missing")
        XCTAssertEqual(registration.registers, 0, "Checking status never registers or prompts")
        XCTAssertEqual(client.requestApproval(), .needsApproval)
        XCTAssertEqual(registration.registers, 1)
        XCTAssertEqual(registration.settingsOpened, 1)
        XCTAssertEqual(logged, ["Keep Awake power helper registration: notFound → requiresApproval, SMAppServiceErrorDomain 1"])
        XCTAssertEqual(client.status(), .needsApproval)
    }

    func testMissingOrRejectedHelperIsUnavailableWithAnExplanation() throws {
        let registration = FakeRegistration()
        registration.status = .notFound
        registration.packaged = false
        let client = makeClient(registration, listener: listen(StalledHelper()), helperRequirement: nil)
        XCTAssertEqual(client.status(), .unavailable(KeepAwakePowerHelper.missingMessage))
        XCTAssertEqual(client.requestApproval(), .unavailable(KeepAwakePowerHelper.missingMessage))
        XCTAssertEqual(registration.registers, 0, "A helper absent from the bundle is never registered")

        registration.packaged = true
        registration.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 3)
        XCTAssertEqual(client.requestApproval(), .unavailable(KeepAwakePowerHelper.rejectedMessage("SMAppServiceErrorDomain 3")))
        registration.status = .notRegistered
        XCTAssertEqual(client.requestApproval(), .unavailable(KeepAwakePowerHelper.rejectedMessage("SMAppServiceErrorDomain 3")))
        registration.registerError = nil
        XCTAssertEqual(client.requestApproval(), .unavailable(KeepAwakePowerHelper.rejectedMessage("notRegistered")))
        XCTAssertEqual(registration.registers, 3)
        XCTAssertEqual(registration.settingsOpened, 0)
    }

    func testPackagedHelperNeedsItsPlistAndTheExecutableItNames() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("KeepAwake-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let daemons = bundle.appendingPathComponent("Contents/Library/LaunchDaemons")
        let plist = daemons.appendingPathComponent(RelayPowerHelperIdentity.plistName)
        let executable = bundle.appendingPathComponent(KeepAwakeHelperRegistration.bundleProgram)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeJob(label: String = RelayPowerHelperIdentity.label,
                      program: String = KeepAwakeHelperRegistration.bundleProgram) {
            XCTAssertTrue(NSDictionary(dictionary: ["Label": label, "BundleProgram": program]).write(to: plist, atomically: true))
        }
        XCTAssertFalse(KeepAwakeHelperRegistration.isPackaged(in: bundle), "No plist")
        writeJob()
        XCTAssertFalse(KeepAwakeHelperRegistration.isPackaged(in: bundle), "No executable")
        try Data().write(to: executable)
        XCTAssertFalse(KeepAwakeHelperRegistration.isPackaged(in: bundle), "Not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertTrue(KeepAwakeHelperRegistration.isPackaged(in: bundle))
        writeJob(label: "com.example.other")
        XCTAssertFalse(KeepAwakeHelperRegistration.isPackaged(in: bundle), "Another job's plist")
        writeJob(program: "Contents/MacOS/../MacOS/\(RelayPowerHelperIdentity.executableName)")
        XCTAssertFalse(KeepAwakeHelperRegistration.isPackaged(in: bundle), "Only the fixed bundle program")
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/LaunchDaemons/\(RelayPowerHelperIdentity.plistName)")
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.copyItem(at: shipped, to: plist)
        XCTAssertTrue(KeepAwakeHelperRegistration.isPackaged(in: bundle), "The plist the build embeds")
    }

    func testClientRefusesAHelperThatIsNotRelaysAndRepairsOnlyOnce() throws {
        let service = makeService(requirement: try ownRequirement())
        let registration = FakeRegistration()
        // The peer is this test process, not Relay's Developer ID helper.
        let client = makeClient(registration, listener: listen(service),
                                helperRequirement: RelayPowerHelperIdentity.helperRequirement)
        XCTAssertEqual(client.status(), .unavailable(KeepAwakePowerHelper.notRespondingMessage))
        XCTAssertEqual(client.hold(), .failed)
        XCTAssertTrue(service.queue.sync { power.sets.isEmpty }, "An unverified helper is never asked to change sleep")
        XCTAssertEqual(registration.unregisters, 1)
        XCTAssertEqual(registration.registers, 1)
        XCTAssertEqual(client.status(), .unavailable(KeepAwakePowerHelper.notRespondingMessage))
        XCTAssertEqual(registration.unregisters, 1, "Re-registration happens at most once per launch")
    }

    func testNewlyAllowedHelperGetsTimeToStartWithoutBeingReRegistered() {
        let registration = FakeRegistration()
        registration.status = .requiresApproval
        // Not answering yet, as when launchd hasn't started it.
        let client = makeClient(registration, listener: listen(makeService(requirement: RelayPowerHelperIdentity.appRequirement)),
                                helperRequirement: nil)
        XCTAssertEqual(client.status(), .needsApproval)
        registration.status = .enabled
        for _ in 1..<KeepAwakePowerHelper.startGraceChecks {
            XCTAssertEqual(client.status(), .needsApproval, "Still starting")
        }
        XCTAssertEqual(client.status(), .unavailable(KeepAwakePowerHelper.notRespondingMessage))
        XCTAssertEqual(registration.unregisters, 0, "A fresh approval is never undone by a re-registration")
        XCTAssertEqual(registration.registers, 0)
    }

    func testStalledHelperTimesOutAndLosesItsConnection() {
        let stalled = StalledHelper()
        let client = makeClient(FakeRegistration(), listener: listen(stalled), helperRequirement: nil, replyTimeout: 0.3)
        let start = Date()
        XCTAssertEqual(client.hold(), .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "Every request is bounded")
        let deadline = Date().addingTimeInterval(5)
        while !stalled.wasInvalidated, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(stalled.wasInvalidated, "A timed-out request drops the connection, ending any hold")
    }

    // MARK: Packaging identifiers

    func testIdentifiersMatchTheLaunchdPlistAndTheAppBundle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("scripts/LaunchDaemons/\(RelayPowerHelperIdentity.plistName)")
        let job = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        XCTAssertEqual(job["Label"] as? String, RelayPowerHelperIdentity.label)
        XCTAssertEqual(job["BundleProgram"] as? String, "Contents/MacOS/\(RelayPowerHelperIdentity.executableName)")
        XCTAssertEqual(job["MachServices"] as? [String: Bool], [RelayPowerHelperIdentity.machServiceName: true])
        XCTAssertEqual(job["AssociatedBundleIdentifiers"] as? [String], [RelayPowerHelperIdentity.appIdentifier])
        XCTAssertNil(job["ProgramArguments"], "launchd runs the fixed bundled executable with no arguments")
        let info = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Info.plist")) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, RelayPowerHelperIdentity.appIdentifier)
        XCTAssertTrue(RelayPowerHelperIdentity.appRequirement.hasPrefix("identifier \"com.relayrunner.app\" and anchor apple generic"))
        XCTAssertTrue(RelayPowerHelperIdentity.helperRequirement.contains("identifier \"\(RelayPowerHelperIdentity.label)\""))
        XCTAssertTrue(RelayPowerHelperIdentity.helperRequirement.contains("subject.OU] = \"\(RelayPowerHelperIdentity.teamIdentifier)\""))
        for requirement in [RelayPowerHelperIdentity.appRequirement, RelayPowerHelperIdentity.helperRequirement] {
            var compiled: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &compiled), errSecSuccess, requirement)
        }
    }
}
