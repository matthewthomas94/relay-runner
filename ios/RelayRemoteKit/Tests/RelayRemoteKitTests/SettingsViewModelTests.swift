import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// RR-544: the Settings tab's Mac-backed state against a scripted Mac: load,
/// set, a refused set, a change pushed from the Mac, and an unreachable or
/// unsupporting Mac.
@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var current = SettingsState()

    private func state(model: String = "opus", speed: Int = 100) -> SettingsState {
        SettingsState(
            speechSpeedPercent: speed, provider: "claude", model: model, effort: "medium", sizing: "orchestrator",
            modelOptions: [SettingOption(value: "opus", label: "Opus"), SettingOption(value: "sonnet", label: "Sonnet")],
            effortOptions: model == "opus"
                ? [SettingOption(value: "medium", label: "Medium"), SettingOption(value: "high", label: "High")]
                : [SettingOption(value: "medium", label: "Medium")],
            sizingOptions: [SettingOption(value: "orchestrator", label: "Orchestrator decides"),
                            SettingOption(value: "defaults", label: "Use my defaults")])
    }

    private func connect(_ mac: FakeMac) async -> (RemoteSession, SettingsViewModel) {
        mac.sessionRunning = true
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock())
        let model = SettingsViewModel(session: session)
        model.start()
        session.start()
        await eventually { session.state == .connected }
        return (session, model)
    }

    private func scriptedMac() -> FakeMac {
        let mac = FakeMac()
        current = state()
        mac.settingsReply = { [unowned self] command in
            guard command.action == .set else { return current }
            if command.effort == "ultra" {
                var refused = current
                refused.error = "Effort 'ultra' is not available."
                return refused
            }
            if let speed = command.speechSpeedPercent { current.speechSpeedPercent = speed }
            if let model = command.model { current = state(model: model, speed: current.speechSpeedPercent ?? 100) }
            if let speed = command.speechSpeedPercent, speed == 999 { current.error = "bad" }
            return current
        }
        return mac
    }

    func testLoadsTheMacsSettingsOnceConnected() async throws {
        let (session, model) = await connect(scriptedMac())
        await eventually { model.phase == .ready }
        XCTAssertEqual(model.speechSpeed, 1.0)
        XCTAssertEqual(model.label(for: model.model, in: model.modelOptions), "Opus")
        XCTAssertEqual(model.label(for: model.sizing, in: model.sizingOptions), "Orchestrator decides")
        session.stop()
    }

    func testLettingGoSendsOneSetWithTheFinalSpeed() async throws {
        let mac = scriptedMac()
        let (session, model) = await connect(mac)
        await eventually { model.phase == .ready }
        let before = mac.settingsCommands.count
        model.dragSpeed(to: 1.1)
        model.dragSpeed(to: 1.26)
        model.dragSpeed(to: 1.3)
        XCTAssertEqual(mac.settingsCommands.count, before, "dragging sends nothing")
        model.commitSpeed(1.3)
        await eventually { session.settings?.speechSpeedPercent == 130 }
        XCTAssertEqual(mac.settingsCommands.count, before + 1)
        XCTAssertEqual(mac.settingsCommands.last?.speechSpeedPercent, 130)
        XCTAssertEqual(model.speechSpeed, 1.3)
        session.stop()
    }

    func testARefusedSpeedReturnsToTheMacsValueAndShowsTheError() async throws {
        let mac = scriptedMac()
        let (session, model) = await connect(mac)
        await eventually { model.phase == .ready }
        mac.settingsReply = { [unowned self] command in
            guard command.action == .set else { return current }
            var refused = current
            refused.error = "Speech speed is locked on this Mac."
            return refused
        }
        model.commitSpeed(1.7)
        await eventually { model.errorLine != nil }
        XCTAssertEqual(model.errorLine, "Speech speed is locked on this Mac.")
        await eventually { model.speechSpeed == 1.0 }
        XCTAssertEqual(model.phase, .ready)
        session.stop()
    }

    func testChoosingAModelSendsASetAndShowsTheRepliesEffortOptions() async throws {
        let mac = scriptedMac()
        let (session, model) = await connect(mac)
        await eventually { model.phase == .ready }
        XCTAssertEqual(model.effortOptions.map(\.value), ["medium", "high"])
        model.choose(model: "sonnet")
        await eventually { model.model == "sonnet" }
        XCTAssertEqual(mac.settingsCommands.last?.model, "sonnet")
        XCTAssertEqual(model.effortOptions.map(\.value), ["medium"])
        session.stop()
    }

    func testARefusedOrchestratorChangeKeepsTheMacsValue() async throws {
        let (session, model) = await connect(scriptedMac())
        await eventually { model.phase == .ready }
        model.choose(effort: "ultra")
        await eventually { model.errorLine != nil }
        XCTAssertEqual(model.effort, "medium")
        session.stop()
    }

    func testAChangePushedFromTheMacUpdatesTheControls() async throws {
        let mac = scriptedMac()
        let (session, model) = await connect(mac)
        await eventually { model.phase == .ready }
        mac.pushSettingsState(state(model: "sonnet", speed: 150))
        await eventually { model.model == "sonnet" }
        XCTAssertEqual(model.speechSpeed, 1.5)
        session.stop()
    }

    func testAMacThatCannotServeSettingsIsUnavailableNotLoading() async throws {
        let mac = FakeMac()
        mac.settingsReply = { _ in SettingsState(error: "Settings cannot be changed from the phone on this Mac yet.") }
        let (session, model) = await connect(mac)
        await eventually { model.phase == .unavailable(SettingsViewModel.unsupportedLine) }
        XCTAssertFalse(model.isEnabled)
        session.stop()
    }

    func testAnUnreachableMacDisablesTheControls() async throws {
        let session = Fixtures.session(transport: FakeTransport(mac: nil), clock: TestClock())
        let model = SettingsViewModel(session: session)
        model.start()
        XCTAssertEqual(model.phase, .unavailable(SettingsViewModel.unreachableLine))
        XCTAssertFalse(model.isEnabled)
    }
}
