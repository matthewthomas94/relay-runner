import RelayRemoteKit
import XCTest
@testable import RelayRemote

@MainActor
final class PairingFlowTests: XCTestCase {
    private static let key = Data(repeating: 7, count: 32).base64EncodedString()
    private static let validCode = """
        {"protocol":1,"user":"matt","hosts":["MacBook-Pro.local","10.0.0.5"],"port":22,
        "host_keys":["SHA256:K7QXM2PD9FHTabcdefghijklmnopqrstuvwxyz01234b81Q"],
        "pairing_id":"p-1","pairing_key":"\(key)","token":"dG9rZW4="}
        """

    /// A pairer the test finishes by hand.
    private final class FakePairer {
        var codes: [String] = []
        var continuation: CheckedContinuation<String?, Never>?
        func pair(_ code: String) async -> String? {
            codes.append(code)
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ result: String?) { continuation?.resume(returning: result); continuation = nil }
    }

    private func make(lifetime: TimeInterval = 600, fake: FakePairer, finished: @escaping () -> Void = {})
        -> PairingFlowModel {
        PairingFlowModel(lifetime: lifetime, pairer: { await fake.pair($0) }, onFinished: finished)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    func testCheckInfoGroupsTheFingerprint() throws {
        let info = try PairingCheckInfo(code: Self.validCode)
        XCTAssertEqual(info.fingerprintGroups, ["K7QX", "M2PD", "9FHT"])
        XCTAssertEqual(info.macName, "MacBook Pro")
        XCTAssertEqual(info.detail, "matt · MacBook-Pro.local")
        XCTAssertEqual(info.abbreviatedHostKey, "SHA256:K7QXM2PD9FHT…b81Q")
    }

    func testValidCodeMovesToCheckAndStartsPairing() async throws {
        let fake = FakePairer()
        let flow = make(fake: fake)
        flow.beginScan()
        flow.submit(Self.validCode)
        guard case .check(let info) = flow.step else { return XCTFail("expected check, got \(flow.step)") }
        XCTAssertEqual(info.fingerprintGroups, ["K7QX", "M2PD", "9FHT"])
        XCTAssertNotNil(flow.expiresAt)
        await settle()
        XCTAssertEqual(fake.codes, [Self.validCode])
    }

    func testInvalidCodeStaysOnScanWithAnError() {
        let fake = FakePairer()
        let flow = make(fake: fake)
        flow.beginScan()
        flow.submit("not a code")
        XCTAssertEqual(flow.step, .scan)
        XCTAssertEqual(flow.scanError, PairingFlowModel.invalidCodeMessage)
        XCTAssertTrue(fake.codes.isEmpty)
    }

    func testApprovalFinishes() async {
        let fake = FakePairer()
        var finished = 0
        let flow = make(fake: fake) { finished += 1 }
        flow.beginScan()
        flow.submit(Self.validCode)
        await settle()
        fake.finish(nil)
        await settle()
        XCTAssertEqual(finished, 1)
    }

    func testDenialReturnsToStartWithMessage() async {
        let fake = FakePairer()
        var finished = 0
        let flow = make(fake: fake) { finished += 1 }
        flow.beginScan()
        flow.submit(Self.validCode)
        await settle()
        fake.finish("You denied this iPhone on your Mac.")
        await settle()
        XCTAssertEqual(flow.step, .start)
        XCTAssertEqual(flow.notice, "You denied this iPhone on your Mac.")
        XCTAssertEqual(finished, 0)
    }

    func testCountdownReachingZeroReturnsToStart() async {
        let fake = FakePairer()
        let flow = make(lifetime: 0.05, fake: fake)
        flow.beginScan()
        flow.submit(Self.validCode)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(flow.step, .start)
        XCTAssertEqual(flow.notice, PairingFlowModel.expiredMessage)
        fake.finish(nil)
        await settle()
        XCTAssertEqual(flow.step, .start, "a late approval after expiry is ignored")
    }

    func testCancelReturnsToStartAndIgnoresLateResult() async {
        let fake = FakePairer()
        var finished = 0
        let flow = make(fake: fake) { finished += 1 }
        flow.beginScan()
        flow.submit(Self.validCode)
        await settle()
        flow.cancel()
        XCTAssertEqual(flow.step, .start)
        XCTAssertNil(flow.notice)
        fake.finish(nil)
        await settle()
        XCTAssertEqual(flow.step, .start)
        XCTAssertEqual(finished, 0)
    }

    func testForgettingTheMacOpensPairing() {
        XCTAssertEqual(AppFlow.initialStage(onboardingFinished: true, paired: false), .pairing)
    }

    func testLaunchOptionReadsThePairingStep() {
        XCTAssertEqual(LaunchOptions(arguments: ["--pairing-step=check"]).pairingStep, "check")
    }
}
