import XCTest
@testable import RelayRemote

@MainActor
final class PermissionsFlowTests: XCTestCase {
    private final class FakeClient: PermissionsClient {
        var statuses: [PermissionStep: PermissionStatus] = [:]
        var answers: [PermissionStep: PermissionStatus] = [:]
        var requested: [PermissionStep] = []

        func status(of step: PermissionStep) async -> PermissionStatus { statuses[step] ?? .undetermined }
        func request(_ step: PermissionStep) async -> PermissionStatus {
            requested.append(step)
            return answers[step] ?? .granted
        }
    }

    private func makeModel(_ client: FakeClient) throws -> (PermissionsFlowModel, ReplyNotificationsPreference, () -> Void) {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preference = ReplyNotificationsPreference(defaults: defaults)
        return (PermissionsFlowModel(client: client, notifications: preference), preference,
                { defaults.removePersistentDomain(forName: suite) })
    }

    func testStepsAppearInOrderAndGrantAdvances() async throws {
        let client = FakeClient()
        let (model, _, cleanup) = try makeModel(client)
        defer { cleanup() }
        await model.load()
        var seen: [PermissionStep] = []
        while let step = model.current {
            seen.append(step)
            await model.grant()
        }
        XCTAssertEqual(seen, [.microphone, .localNetwork, .camera, .notifications])
        XCTAssertEqual(client.requested, seen)
    }

    func testSkipAdvancesWithoutAsking() async throws {
        let client = FakeClient()
        let (model, _, cleanup) = try makeModel(client)
        defer { cleanup() }
        await model.load()
        while model.current != nil { model.skip() }
        XCTAssertTrue(client.requested.isEmpty)
    }

    func testDecidedStepsAreLeftOut() async throws {
        let client = FakeClient()
        client.statuses = [.microphone: .granted, .camera: .denied]
        let (model, _, cleanup) = try makeModel(client)
        defer { cleanup() }
        await model.load()
        XCTAssertEqual(model.current, .localNetwork)
        model.skip()
        XCTAssertEqual(model.current, .notifications)
    }

    func testNotificationsPreferenceFollowsTheAnswer() async throws {
        for (answer, expected) in [(PermissionStatus.granted, true), (.denied, false)] {
            let client = FakeClient()
            client.statuses = [.microphone: .granted, .localNetwork: .granted, .camera: .granted]
            client.answers[.notifications] = answer
            let (model, preference, cleanup) = try makeModel(client)
            defer { cleanup() }
            preference.isOn = !expected
            await model.load()
            await model.grant()
            XCTAssertEqual(preference.isOn, expected)
            XCTAssertNil(model.current)
        }
    }

    func testSkippingNotificationsLeavesThemOff() async throws {
        let client = FakeClient()
        client.statuses = [.microphone: .granted, .localNetwork: .granted, .camera: .granted]
        let (model, preference, cleanup) = try makeModel(client)
        defer { cleanup() }
        await model.load()
        model.skip()
        XCTAssertFalse(preference.isOn)
    }
}
