import Darwin
import XCTest
@testable import relay_runner

final class AssistantManagedProviderProcessTests: XCTestCase {
    private func spawnChild(_ executable: String, arguments: [String] = []) throws -> Int32 {
        var pid: pid_t = 0
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        sigaddset(&mask, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let result = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, executable, nil, &attributes, $0.baseAddress!, environ)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        addTeardownBlock {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
        return pid
    }

    private func waitForZombie(_ pid: Int32) async throws {
        for _ in 0..<100 {
            if AssistantManagedProviderProcess.isZombie(Int(pid)) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected exited child to await reaping")
    }

    func testZombieIsExitedEvenWhenKillZeroSucceeds() async throws {
        let pid = try spawnChild("/usr/bin/true")
        try await waitForZombie(pid)
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        XCTAssertFalse(AssistantManagedProviderProcess.isAlive(Int(pid)))
        let saved = AssistantManagedProviderProcess(pid: Int(pid), identity: "stopped child")
        XCTAssertEqual(saved.state(identityForPID: { _ in XCTFail("Zombie owns no work"); return nil }), .exited)
        XCTAssertTrue(saved.requestTermination(terminate: { _ in XCTFail("Zombie must not be signaled"); return false }))
        await AssistantManagedProviderProcess.reapExplicitlyStoppedChild(Int(pid))?.value
    }

    func testExplicitStopReapsOnlyExactDirectChild() async throws {
        let stopped = try spawnChild("/bin/sleep", arguments: ["10"])
        let other = try spawnChild("/usr/bin/true")
        try await waitForZombie(other)
        XCTAssertNil(AssistantManagedProviderProcess.reapExplicitlyStoppedChild(Int(getpid())))
        XCTAssertEqual(Darwin.kill(stopped, SIGTERM), 0)
        let reaper = try XCTUnwrap(AssistantManagedProviderProcess.reapExplicitlyStoppedChild(Int(stopped)))
        await reaper.value
        var status: Int32 = 0
        XCTAssertEqual(waitpid(stopped, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertTrue(AssistantManagedProviderProcess.isZombie(Int(other)), "An unrelated child's status remains for its monitor")
        await AssistantManagedProviderProcess.reapExplicitlyStoppedChild(Int(other))?.value
    }

    func testCrashSurvivorMustHaveExactBirthIdentityBeforeTermination() {
        let saved = AssistantManagedProviderProcess(pid: 42, identity: "birth uid group")
        var signaled: [Int] = []
        XCTAssertEqual(saved.state(identityForPID: { _ in "birth uid group" }, isAlive: { _ in true }), .matching)
        XCTAssertTrue(saved.requestTermination(identityForPID: { _ in "birth uid group" }, isAlive: { _ in true }, terminate: { signaled.append($0); return true }))
        XCTAssertEqual(signaled, [42])
        // Sending SIGTERM is not evidence that replacement may start.
        XCTAssertEqual(saved.state(identityForPID: { _ in "birth uid group" }, isAlive: { _ in true }), .matching)
        XCTAssertEqual(saved.state(identityForPID: { _ in nil }, isAlive: { _ in false }), .exited)
    }

    func testStaleReusedPIDNeverReceivesASignal() {
        let saved = AssistantManagedProviderProcess(pid: 42, identity: "old birth")
        XCTAssertEqual(saved.state(identityForPID: { _ in "different birth" }, isAlive: { _ in true }), .stale)
        XCTAssertTrue(saved.requestTermination(identityForPID: { _ in "different birth" }, isAlive: { _ in true }, terminate: { _ in XCTFail("Unrelated PID must not be signaled"); return false }))
    }

    func testUnknownLiveIdentityBlocksReplacementAndReconnectFailureIsPreserved() {
        let saved = AssistantManagedProviderProcess(pid: 42, identity: "old birth")
        XCTAssertEqual(saved.state(identityForPID: { _ in nil }, isAlive: { _ in true }), .unknown)
        XCTAssertFalse(saved.requestTermination(identityForPID: { _ in nil }, isAlive: { _ in true }, terminate: { _ in XCTFail("Unknown PID must not be signaled"); return true }))
        XCTAssertFalse(saved.requestTermination(identityForPID: { _ in "old birth" }, isAlive: { _ in true }, terminate: { _ in false }))
    }

    func testActiveCrashSurvivorDefersReplacementEvenWithoutAnAttachedTerminal() {
        for state in [AssistantManagedProviderProcess.State.matching, .unknown] {
            XCTAssertTrue(AssistantSessionStore.shouldDeferReplacement(hasEmbeddedProvider: false, managedProcessStates: [state], canReplace: false))
            XCTAssertFalse(AssistantSessionStore.shouldDeferReplacement(hasEmbeddedProvider: false, managedProcessStates: [state], canReplace: true))
        }
        XCTAssertFalse(AssistantSessionStore.shouldDeferReplacement(hasEmbeddedProvider: false, managedProcessStates: [.stale, .exited], canReplace: false))
        XCTAssertTrue(AssistantSessionStore.shouldDeferReplacement(hasEmbeddedProvider: true, managedProcessStates: [], canReplace: false))
    }
}
