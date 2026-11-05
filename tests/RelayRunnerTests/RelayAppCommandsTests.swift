import CoreImage
import CryptoKit
import Foundation
import RelayRemoteProtocol
import XCTest
@testable import relay_app_mcp
@testable import relay_runner

/// RR-459: Relay App's app-side commands through injected AppState closures,
/// a real Relay Remote controller on a temporary HOME, and the session-control
/// socket they share with the phone.
@MainActor
final class RelayAppCommandsTests: XCTestCase {
    private final class FakeApp {
        var projects = [
            RelaySessionControlHost.Project(id: "p-relay", name: "relay-runner", path: "/repos/relay-runner", availability: "available"),
            RelaySessionControlHost.Project(id: "p-notes", name: "notes", path: "/repos/notes", availability: "available"),
        ]
        var snapshot = RelaySessionControlHost.Snapshot()
        var started: [String] = []
        var stops = 0
        var config = AppConfig()
        var saves: [AppConfig] = []
        var configManager: ConfigManager?
        var destinations: [RelayAppDestination] = []
        var navigationRefusal: String?
        var selected: [String] = []
        var keepAwake = KeepAwakeState.off
        var toggles = 0
        var onToggle: (KeepAwakeState) -> KeepAwakeState = { state in
            switch state {
            case .off, .failed: return .enabling
            case .on: return .disabling
            case .awaitingApproval, .restoreNeeded: return .off
            default: return state
            }
        }

        var sessionHost: RelaySessionControlHost {
            RelaySessionControlHost(
                projects: { self.projects },
                snapshot: { self.snapshot },
                start: { path in
                    self.started.append(path)
                    self.snapshot.launching = true
                    return true
                },
                stop: {
                    self.stops += 1
                    self.snapshot = .init()
                },
                message: { nil }
            )
        }

        var appHost: RelayAppCommandHost {
            RelayAppCommandHost(
                status: {
                    [
                        "app": ["version": "9.9.9", "build": "999"],
                        "permissions": RelayAppCommands.permissions { $0 == .microphone ? .granted : .notDetermined },
                        "relay_remote": ["remote_mode": true, "remote_mode_label": "Remote: Test iPhone"],
                    ]
                },
                navigate: { destination in
                    if let refusal = self.navigationRefusal { return refusal }
                    self.destinations.append(destination)
                    return nil
                },
                config: { self.config },
                saveConfig: { config in
                    self.saves.append(config)
                    self.config = config
                    try? self.configManager?.save(config)
                },
                selectProject: { id in
                    self.selected.append(id)
                    return id == "p-notes" ? .success("Opened the notes board.") : .failure(RelayAppCommandError("No registered project has id '\(id)'."))
                },
                keepAwakeState: { self.keepAwake },
                toggleKeepAwake: {
                    self.toggles += 1
                    guard !self.keepAwake.isPending else { return false }
                    self.keepAwake = self.onToggle(self.keepAwake)
                    return true
                }
            )
        }
    }

    private var root: URL!
    private var environment: RelayRemoteEnvironment!
    private var app: FakeApp!
    private var remote: RelayRemoteController!
    private var commands: RelayAppCommands!

    override func setUp() async throws {
        // Short path: the pair socket must fit in sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/rra-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        environment = RelayRemoteEnvironment(
            home: home,
            supportDirectory: support,
            pairSocketPath: root.appendingPathComponent("pair.sock").path,
            hostKeyDirectory: root,
            sshPort: 22,
            userName: NSUserName(),
            log: { _ in }
        )
        app = FakeApp()
        app.configManager = ConfigManager(configDir: support)
        remote = RelayRemoteController(
            environment: environment,
            hostCandidates: { ["mac.local", "192.168.1.5"] },
            networkRanges: { ["192.168.1.0/24", "100.64.0.0/10"] }
        )
        commands = RelayAppCommands(host: app.appHost, session: RelaySessionControl(host: app.sessionHost), remote: remote)
        commands.settleTimeout = 5
    }

    override func tearDown() async throws {
        remote.cancelPairing()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func ok(_ command: String, _ arguments: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        switch await commands.run(command, arguments) {
        case .success(let result): return result
        case .failure(let error):
            XCTFail("\(command) failed: \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func refused(_ command: String, _ arguments: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) async -> String {
        switch await commands.run(command, arguments) {
        case .success(let result):
            XCTFail("\(command) unexpectedly succeeded: \(result)", file: file, line: line)
            return ""
        case .failure(let error): return error.message
        }
    }

    // MARK: Parser

    func testEveryAdvertisedCommandIsHandledAndUnknownOnesAreRefused() async throws {
        XCTAssertEqual(Set(RelayAppCommands.commandNames), Set(AppTools.all(client: AppControlClient()).map(\.name)))
        for name in RelayAppCommands.commandNames {
            let message = await refused(name, ["unexpected": 1])
            XCTAssertTrue(message.contains("does not accept unexpected"), "\(name): \(message)")
        }
        let unknown = await refused("format_disk")
        XCTAssertTrue(unknown.hasPrefix("Unknown Relay App command 'format_disk'"))
        let missing = await commands.handle(["type": "app_command"])
        XCTAssertEqual(missing.failureMessage, "app_command needs a command.")
        let badArguments = await commands.handle(["command": "app_status", "arguments": "all"])
        XCTAssertEqual(badArguments.failureMessage, "app_command arguments must be an object.")
        let wrongType = await refused("keep_awake", ["on": "yes"])
        XCTAssertEqual(wrongType, "on must be true or false.")
    }

    func testResultsEncodeAsAppResultLines() throws {
        let success = RelayAppCommands.encode(id: "r1", .success(["opened": "workspace"]))
        XCTAssertEqual(String(decoding: success, as: UTF8.self), #"{"id":"r1","ok":true,"result":{"opened":"workspace"},"type":"app_result"}"# + "\n")
        let failure = RelayAppCommands.encode(id: "r2", .failure(RelayAppCommandError("No.")))
        XCTAssertEqual(String(decoding: failure, as: UTF8.self), #"{"error":"No.","id":"r2","ok":false,"type":"app_result"}"# + "\n")
    }

    // MARK: Status and navigation

    func testAppStatusReportsVersionSessionRemoteAndKeepAwake() async throws {
        let status = try await ok("app_status")
        XCTAssertEqual((status["app"] as? [String: Any])?["version"] as? String, "9.9.9")
        XCTAssertEqual((status["session"] as? [String: Any])?["session"] as? String, "none")
        XCTAssertEqual((status["permissions"] as? [String: String])?["microphone"], "granted")
        XCTAssertEqual((status["permissions"] as? [String: String])?["screen_recording"], "not_determined")
        let remoteInfo = try XCTUnwrap(status["relay_remote"] as? [String: Any])
        XCTAssertEqual(remoteInfo["remote_mode"] as? Bool, true)
        XCTAssertEqual(remoteInfo["paired_devices"] as? Int, 0)
        XCTAssertEqual(remoteInfo["pairing"] as? String, "idle")
        XCTAssertEqual((status["keep_awake"] as? [String: Any])?["state"] as? String, "off")
    }

    func testNavigateOpensEachSurfaceAndSettingsPage() async throws {
        try await ok("navigate", ["destination": "workspace"])
        try await ok("navigate", ["destination": "notetaker"])
        try await ok("navigate", ["destination": "terminal"])
        try await ok("navigate", ["destination": "settings"])
        let page = try await ok("navigate", ["destination": "settings", "settings_page": "relay_remote"])
        XCTAssertEqual(page["settings_page"] as? String, "relay_remote")
        XCTAssertEqual(app.destinations, [.workspace, .notetaker, .terminal, .settings(nil), .settings(.relayRemote)])
        for (name, category) in RelayAppCommands.settingsPages {
            try await ok("navigate", ["destination": "settings", "settings_page": name])
            XCTAssertEqual(app.destinations.last, .settings(category))
        }
        XCTAssertEqual(Set(RelayAppCommands.settingsPages.values), Set(SettingsCategory.allCases))

        let unknownPage = await refused("navigate", ["destination": "settings", "settings_page": "secrets"])
        XCTAssertTrue(unknownPage.hasPrefix("Unknown settings_page 'secrets'"))
        let misplaced = await refused("navigate", ["destination": "workspace", "settings_page": "general"])
        XCTAssertEqual(misplaced, "settings_page applies only to destination settings.")
        app.navigationRefusal = "Relay Runner is still in first-run setup."
        let blocked = await refused("navigate", ["destination": "workspace"])
        XCTAssertEqual(blocked, "Relay Runner is still in first-run setup.")
    }

    // MARK: Weakly held AppState

    /// Stands in for `AppState` behind `RelayAppCommandHost(weaklyHolding:)`.
    private final class WeakOwner: RelayAppCommandOwner {
        var refusal: String?
        var destinations: [RelayAppDestination] = []
        var relayAppStatus: [String: Any] { ["app": ["version": "1.0", "build": "1"]] }
        func openRelayAppDestination(_ destination: RelayAppDestination) -> String? {
            if let refusal { return refusal }
            destinations.append(destination)
            return nil
        }
        var relayAppConfig = AppConfig()
        func saveRelayAppConfig(_ config: AppConfig) { relayAppConfig = config }
        @MainActor func selectRelayAppProject(_ projectID: String) async -> Result<String, RelayAppCommandError> {
            projectID == "p-notes" ? .success("Opened the notes board.") : .failure(RelayAppCommandError("No project '\(projectID)'."))
        }
        var relayAppKeepAwakeState = KeepAwakeState.off
        func toggleRelayAppKeepAwake() -> Bool { true }
    }

    private func bind(_ owner: WeakOwner) {
        commands = RelayAppCommands(
            host: RelayAppCommandHost(weaklyHolding: owner),
            session: RelaySessionControl(host: app.sessionHost),
            remote: remote
        )
        commands.settleTimeout = 5
    }

    func testWeaklyHeldNavigateSeparatesSuccessRefusalAndAGoneApp() async throws {
        var owner: WeakOwner? = WeakOwner()
        bind(owner!)
        let opened = try await ok("navigate", ["destination": "settings", "settings_page": "relay_remote"])
        XCTAssertEqual(opened["opened"] as? String, "settings")
        XCTAssertEqual(owner?.destinations, [.settings(.relayRemote)])

        owner?.refusal = "Relay Runner is still in first-run setup."
        let refusedNavigation = await refused("navigate", ["destination": "workspace"])
        XCTAssertEqual(refusedNavigation, "Relay Runner is still in first-run setup.")

        let host = RelayAppCommandHost(weaklyHolding: owner!)
        owner = nil
        XCTAssertEqual(host.navigate(.workspace), RelayAppCommandHost.quittingMessage)
        XCTAssertFalse(host.isAvailable())
        let selection = await host.selectProject("p-notes")
        guard case .failure(let error) = selection else { return XCTFail("select_project succeeded without an app") }
        XCTAssertEqual(error.message, RelayAppCommandHost.quittingMessage)
        let gone: [(String, [String: Any])] = [
            ("app_status", [:]),
            ("navigate", ["destination": "workspace"]),
            ("get_settings", [:]),
            ("set_settings", ["settings": ["tts": ["rate": 1.1]]]),
            ("select_project", ["project_id": "p-notes"]),
            ("keep_awake", ["on": true]),
        ]
        for (command, arguments) in gone {
            let message = await refused(command, arguments)
            XCTAssertEqual(message, RelayAppCommandHost.quittingMessage, command)
        }
    }

    func testWeaklyHeldSelectProjectPassesResultsThrough() async throws {
        let owner = WeakOwner()
        bind(owner)
        let selected = try await ok("select_project", ["project_id": "p-notes"])
        XCTAssertEqual(selected["message"] as? String, "Opened the notes board.")
        let missing = await refused("select_project", ["project_id": "p-gone"])
        XCTAssertEqual(missing, "No project 'p-gone'.")
    }

    func testWeaklyHeldBeginPairingReportsTheCodeShownUnlessNavigationIsRefused() async throws {
        let owner = WeakOwner()
        bind(owner)
        let shown = try await ok("relay_remote_begin_pairing")
        XCTAssertEqual(shown["pairing"] as? String, "showing_code")
        XCTAssertTrue((shown["qr_code"] as? String ?? "").hasPrefix("Shown on Settings > Relay Remote."), "\(shown)")
        XCTAssertEqual(owner.destinations, [.settings(.relayRemote)])

        remote.cancelPairing()
        owner.refusal = "Relay Runner is still in first-run setup."
        let hidden = try await ok("relay_remote_begin_pairing")
        XCTAssertEqual(hidden["qr_code"] as? String, "Not shown: Relay Runner is still in first-run setup. Open Settings > Relay Remote to show it.")
    }

    // MARK: Settings

    func testSetSettingsAppliesAPartialUpdateThroughSaveAndWritesConfigToml() async throws {
        let read = try await ok("get_settings")
        XCTAssertEqual(((read["settings"] as? [String: Any])?["tts"] as? [String: Any])?["rate"] as? Double, 1.3)
        XCTAssertEqual(read["read_only"] as? [String], ["stt.phonon_migration", "stt.phonon_migration_previous_model"])

        let result = try await ok("set_settings", ["settings": ["tts": ["rate": 1.1, "auto_play": true], "awareness": ["glow_intensity": 0.25]]])
        XCTAssertEqual(result["changed"] as? [String], ["awareness.glow_intensity", "tts.auto_play", "tts.rate"])
        XCTAssertEqual(app.saves.count, 1)
        XCTAssertEqual(app.config.tts.rate, 1.1)
        XCTAssertTrue(app.config.tts.auto_play)
        XCTAssertEqual(app.config.awareness.glow_intensity, 0.25)
        XCTAssertEqual(app.config.general, AppConfig().general, "untouched sections are unchanged")
        let toml = try String(contentsOf: root.appendingPathComponent("support/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("rate = 1.1"), toml)
        XCTAssertTrue(toml.contains("auto_play = true"), toml)
        XCTAssertEqual(ConfigManager(configDir: root.appendingPathComponent("support")).load().tts.rate, 1.1)

        let again = try await ok("set_settings", ["settings": ["tts": ["rate": 1.1]]])
        XCTAssertEqual(again["changed"] as? [String], [])
        XCTAssertEqual(app.saves.count, 1, "an unchanged update does not save again")
    }

    func testSetSettingsRefusesUnknownReadOnlyMistypedAndInvalidValues() async throws {
        let cases: [([String: Any], String)] = [
            (["voice": ["rate": 1]], "Unknown settings section 'voice'"),
            (["tts": ["speed": 1]], "Unknown setting 'tts.speed'"),
            (["tts": [String: Any]()], "settings.tts must be an object"),
            (["stt": ["phonon_migration": "completed"]], "'stt.phonon_migration' is recorded by Relay Runner"),
            (["tts": ["rate": "fast"]], "Invalid value for 'tts.rate': expected a number."),
            (["awareness": ["screen_glow": 1]], "Invalid value for 'awareness.screen_glow': expected true or false."),
            (["tts": ["voice": NSNull()]], "'tts.voice' cannot be cleared."),
            (["general": ["provider": "gemini"]], "'general.provider' must be one of: codex, claude."),
            (["general": ["model": "gpt-9"]], "'general.model' cannot be 'gpt-9'"),
        ]
        for (patch, expected) in cases {
            let message = await refused("set_settings", ["settings": patch])
            XCTAssertTrue(message.contains(expected), "\(patch): \(message)")
        }
        let empty = await refused("set_settings", ["settings": [String: Any]()])
        XCTAssertTrue(empty.hasPrefix("settings must name at least one setting"))
        let missing = await refused("set_settings")
        XCTAssertTrue(missing.hasPrefix("set_settings needs settings"))
        XCTAssertTrue(app.saves.isEmpty)
    }

    func testChoosingAProviderResetsItsModelAsTheSettingsPickerDoes() async throws {
        let result = try await ok("set_settings", ["settings": ["general": ["provider": "claude"]]])
        XCTAssertEqual(app.config.general.provider, .claude)
        XCTAssertEqual(app.config.general.model, GeneralConfig.defaultClaudeModel)
        XCTAssertEqual(app.config.general.command, "claude")
        XCTAssertTrue((result["changed"] as? [String])?.contains("general.model") == true)

        try await ok("set_settings", ["settings": ["general": ["model": "sonnet"]]])
        XCTAssertEqual(app.config.general.model, "sonnet")
        let invalid = await refused("set_settings", ["settings": ["general": ["model": "sol"]]])
        XCTAssertTrue(invalid.contains("Relay Runner would use 'opus'"), invalid)

        // The custom voice is the one optional setting, so it alone can be cleared.
        try await ok("set_settings", ["settings": ["tts": ["custom_voice_id": "voice-1"]]])
        XCTAssertEqual(app.config.tts.custom_voice_id, "voice-1")
        try await ok("set_settings", ["settings": ["tts": ["custom_voice_id": NSNull()]]])
        XCTAssertNil(app.config.tts.custom_voice_id)
    }

    // MARK: Projects and sessions

    func testProjectAndSessionCommandsUseTheSessionControlPaths() async throws {
        let list = try await ok("list_projects")
        XCTAssertEqual((list["projects"] as? [[String: Any]])?.compactMap { $0["project_id"] as? String }, ["p-relay", "p-notes"])

        let selected = try await ok("select_project", ["project_id": "p-notes"])
        XCTAssertEqual(selected["message"] as? String, "Opened the notes board.")
        let unknown = await refused("select_project", ["project_id": "p-gone"])
        XCTAssertEqual(unknown, "No registered project has id 'p-gone'.")
        XCTAssertEqual(app.selected, ["p-notes", "p-gone"])

        let started = try await ok("start_session", ["project_id": "p-relay"])
        XCTAssertEqual(started["session"] as? String, "starting")
        XCTAssertEqual(started["project_id"] as? String, "p-relay")
        XCTAssertEqual(app.started, ["/repos/relay-runner"])

        app.snapshot = .init(live: [.init(projectID: "p-relay", name: "relay-runner")])
        let busy = await refused("start_session", ["project_id": "p-notes"])
        XCTAssertEqual(busy, "relay-runner is already running on this Mac. Stop it before starting notes.")

        let unconfirmed = await refused("end_session")
        XCTAssertEqual(unconfirmed, "Refused: end_session ends every running session. Pass confirm: true to proceed.")
        let notTrue = await refused("end_session", ["confirm": false])
        XCTAssertTrue(notTrue.hasPrefix("Refused"))
        XCTAssertEqual(app.stops, 0)
        let ended = try await ok("end_session", ["confirm": true])
        XCTAssertEqual(ended["ended"] as? Bool, true)
        XCTAssertEqual((ended["session"] as? [String: Any])?["session"] as? String, "none")
        XCTAssertEqual(app.stops, 1)
        let idle = try await ok("end_session", ["confirm": true])
        XCTAssertEqual(idle["ended"] as? Bool, false)
        XCTAssertEqual(app.stops, 1)
    }

    // MARK: Keep Awake

    func testKeepAwakeIsIdempotentAndReportsPendingStates() async throws {
        let off = try await ok("keep_awake", ["on": false])
        XCTAssertEqual(off["changed"] as? Bool, false)
        XCTAssertEqual(app.toggles, 0)

        let enabling = try await ok("keep_awake", ["on": true])
        XCTAssertEqual(enabling["state"] as? String, "enabling")
        XCTAssertEqual(enabling["pending"] as? Bool, true)
        XCTAssertEqual(enabling["changed"] as? Bool, true)
        let stillPending = try await ok("keep_awake", ["on": true])
        XCTAssertEqual(stillPending["changed"] as? Bool, false)
        XCTAssertEqual(app.toggles, 1, "a pending change is reported, not toggled again")

        app.keepAwake = .awaitingApproval
        let waiting = try await ok("keep_awake", ["on": true])
        XCTAssertEqual(waiting["state"] as? String, "awaiting_approval")
        XCTAssertEqual(app.toggles, 1, "turning on again must not cancel the approval")

        app.keepAwake = .on(ownsSleepSetting: true)
        let alreadyOn = try await ok("keep_awake", ["on": true])
        XCTAssertEqual(alreadyOn["on"] as? Bool, true)
        XCTAssertEqual(app.toggles, 1)
        let disabling = try await ok("keep_awake", ["on": false])
        XCTAssertEqual(disabling["state"] as? String, "disabling")
        XCTAssertEqual(app.toggles, 2)

        app.keepAwake = .restoreNeeded("Sleep is still disabled.")
        let blocked = await refused("keep_awake", ["on": true])
        XCTAssertTrue(blocked.hasPrefix("Relay Runner must restore system sleep"))
        try await ok("keep_awake", ["on": false])
        XCTAssertEqual(app.keepAwake, .off)
    }

    // MARK: Relay Remote

    func testPairingCompletesWithTheNetworkRestrictionAndUnpairNeedsConfirm() async throws {
        let none = try await ok("relay_remote_pending_approval")
        XCTAssertEqual(none["pending"] as? Bool, false)
        let nothingToApprove = await refused("relay_remote_approve", ["restrict_to_network": true])
        XCTAssertTrue(nothingToApprove.hasPrefix("No device is waiting for approval"))

        let begun = try await ok("relay_remote_begin_pairing")
        XCTAssertEqual(begun["pairing"] as? String, "showing_code")
        XCTAssertEqual(begun["started"] as? Bool, true)
        XCTAssertEqual(begun["hosts"] as? [String], ["mac.local", "192.168.1.5"])
        XCTAssertGreaterThan(begun["expires_in_seconds"] as? Int ?? 0, 500)
        XCTAssertEqual(app.destinations, [.settings(.relayRemote)], "the code is shown where the phone can scan it")
        let again = try await ok("relay_remote_begin_pairing")
        XCTAssertEqual(again["started"] as? Bool, false)
        XCTAssertEqual(again["pairing_id"] as? String, begun["pairing_id"] as? String)

        // The phone scans the code shown in Settings; the tool result never carries its secrets.
        let payload = try scannedPayload()
        let token = try XCTUnwrap(payload["token"] as? String)
        let pairingID = try XCTUnwrap(payload["pairing_id"] as? String)
        XCTAssertEqual(pairingID, begun["pairing_id"] as? String)
        let resultText = String(decoding: try JSONSerialization.data(withJSONObject: begun), as: UTF8.self)
        XCTAssertFalse(resultText.contains(token))
        XCTAssertFalse(resultText.contains(try XCTUnwrap(payload["pairing_key"] as? String)))

        let key = phoneKey()
        let pairPath = environment.pairSocketPath
        let frame = pairFrame(token: token, deviceID: "phone-1", key: key)
        let phone = Task.detached {
            try Self.sendThroughPairSocket(pairPath, [#"{"type":"identify","pairing_id":"\#(pairingID)"}"#, frame])
        }

        var pending: [String: Any] = [:]
        for _ in 0..<250 where pending["pending"] as? Bool != true {
            try await Task.sleep(nanoseconds: 20_000_000)
            pending = try await ok("relay_remote_pending_approval")
        }
        XCTAssertEqual(pending["device_name"] as? String, "Test iPhone")
        XCTAssertEqual(pending["device_id"] as? String, "phone-1")
        XCTAssertEqual(pending["fingerprint"] as? String, key.fingerprint)
        let busy = await refused("relay_remote_begin_pairing")
        XCTAssertTrue(busy.hasPrefix("A device is already waiting for approval"))

        let approved = try await ok("relay_remote_approve", ["restrict_to_network": true])
        XCTAssertEqual(approved["outcome"] as? String, "paired")
        XCTAssertEqual((approved["device"] as? [String: Any])?["restricted_to_network"] as? Bool, true)
        let phoneReply = try await phone.value
        XCTAssertEqual(phoneReply, #"{"device_id":"phone-1","type":"paired"}"#)
        let lines = authorizedKeys().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "command=\"'\(environment.shimURL.path)' --device phone-1\",restrict,from=\"192.168.1.0/24,100.64.0.0/10\" \(key.openSSH) relay-remote:phone-1",
        ])

        let status = try await ok("app_status")
        XCTAssertEqual((status["relay_remote"] as? [String: Any])?["paired_devices"] as? Int, 1)
        let devices = try await ok("relay_remote_devices")
        XCTAssertEqual((devices["devices"] as? [[String: Any]])?.first?["name"] as? String, "Test iPhone")

        let unconfirmed = await refused("relay_remote_unpair", ["device_id": "phone-1"])
        XCTAssertTrue(unconfirmed.hasPrefix("Refused: relay_remote_unpair"))
        XCTAssertEqual(authorizedKeys().split(separator: "\n").count, 1)
        let unknown = await refused("relay_remote_unpair", ["device_id": "phone-9", "confirm": true])
        XCTAssertTrue(unknown.hasPrefix("No paired device has id 'phone-9'"))
        let unpaired = try await ok("relay_remote_unpair", ["device_id": "phone-1", "confirm": true])
        XCTAssertEqual(unpaired["unpaired"] as? String, "phone-1")
        XCTAssertEqual(authorizedKeys(), "")
    }

    func testDenyDeclinesTheWaitingPhone() async throws {
        try await ok("relay_remote_begin_pairing")
        let payload = try scannedPayload()
        let pairingID = try XCTUnwrap(payload["pairing_id"] as? String)
        let pairPath = environment.pairSocketPath
        let frame = pairFrame(token: try XCTUnwrap(payload["token"] as? String), deviceID: "phone-2", key: phoneKey())
        let phone = Task.detached {
            try Self.sendThroughPairSocket(pairPath, [#"{"type":"identify","pairing_id":"\#(pairingID)"}"#, frame])
        }
        for _ in 0..<250 {
            if case .confirming = remote.phase { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let denied = try await ok("relay_remote_deny")
        XCTAssertEqual(denied["outcome"] as? String, "denied")
        let reply = try await phone.value
        XCTAssertTrue(reply.contains("pairing_denied"), reply)
        XCTAssertEqual(authorizedKeys(), "")
    }

    // MARK: Socket loopback

    func testRelayAppMCPDrivesTheAppOverTheSessionControlSocket() async throws {
        let path = root.appendingPathComponent("c.sock").path
        let control = RelaySessionControl(host: app.sessionHost)
        let commands = RelayAppCommands(host: app.appHost, session: control, remote: remote)
        let server = RelaySessionControlServer(control: control, commands: commands, path: path,
                                               bridgePath: root.appendingPathComponent("b.sock").path, tickInterval: 0.05)
        try server.start()
        defer { server.stop() }

        let fired = FiredTools()
        let mcp = relay_app_mcp.MCPServer(client: AppControlClient(path: path, timeoutSeconds: 10), notify: { fired.append($0) })
        func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
            let reply = try await Task.detached {
                try await mcp.dispatch(method: "tools/call", params: ["name": name, "arguments": arguments]) as? [String: Any]
            }.value
            let text = ((reply?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, reply?["isError"] as? Bool ?? true)
        }

        let navigated = try await call("navigate", ["destination": "settings", "settings_page": "relay_remote"])
        XCTAssertFalse(navigated.isError, navigated.text)
        XCTAssertTrue(navigated.text.contains(#""settings_page" : "relay_remote""#), navigated.text)
        XCTAssertEqual(app.destinations, [.settings(.relayRemote)])

        let saved = try await call("set_settings", ["settings": ["tts": ["rate": 1.5]]])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertEqual(app.config.tts.rate, 1.5)
        let rejected = try await call("set_settings", ["settings": ["tts": ["loudness": 11]]])
        XCTAssertTrue(rejected.isError)
        XCTAssertTrue(rejected.text.hasPrefix("Unknown setting 'tts.loudness'"), rejected.text)

        let begun = try await call("relay_remote_begin_pairing")
        XCTAssertFalse(begun.isError, begun.text)
        let pending = try await call("relay_remote_pending_approval")
        XCTAssertTrue(pending.text.contains(#""pending" : false"#), pending.text)

        let refusedEnd = try await call("end_session")
        XCTAssertTrue(refusedEnd.isError)
        XCTAssertTrue(refusedEnd.text.hasPrefix("Refused: end_session is destructive"))
        XCTAssertEqual(fired.names, ["navigate", "set_settings", "relay_remote_begin_pairing", "relay_remote_pending_approval"])

        // A connection that opened as the phone's helper never reaches app commands.
        let phone = try LineClient(path: path)
        phone.send(#"{"device_id":"phone-1","type":"identify"}"#)
        phone.send(#"{"arguments":{"device_id":"phone-1","confirm":true},"command":"relay_remote_unpair","id":"x1","type":"app_command"}"#)
        var refusal: [String: Any] = [:]
        while refusal["type"] as? String != "app_result" { refusal = try await phone.object() }
        XCTAssertEqual(refusal["ok"] as? Bool, false)
        XCTAssertEqual(refusal["error"] as? String, "App commands are not accepted on this connection.")
    }

    // MARK: Helpers

    private func scannedPayload() throws -> [String: Any] {
        guard case .showingCode(let code) = remote.phase else { throw XCTSkip("no pairing code is showing") }
        let image = CIImage(cgImage: code.image)
        let canvas = CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -64, dy: -64))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let message = try XCTUnwrap((detector.features(in: image.composited(over: canvas)).first as? CIQRCodeFeature)?.messageString)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    }

    private func phoneKey() -> SSHPublicKey {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        var blob = Data()
        blob.appendSSHString(Data("ecdsa-sha2-nistp256".utf8))
        blob.appendSSHString(Data("nistp256".utf8))
        blob.appendSSHString(point)
        return SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 \(blob.base64EncodedString())")!
    }

    private func pairFrame(token: String, deviceID: String, key: SSHPublicKey) -> String {
        let object: [String: String] = [
            "type": "pair", "token": token, "device_id": deviceID,
            "device_name": "Test iPhone", "public_key": key.openSSH,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Plays the `--pair` helper: identify, then the phone's frame, then the reply.
    nonisolated private static func sendThroughPairSocket(_ path: String, _ lines: [String]) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        let out = Data((lines.joined(separator: "\n") + "\n").utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var reply = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A { reply.append(byte) }
        return String(decoding: reply, as: UTF8.self)
    }

    private func authorizedKeys() -> String {
        String(decoding: FileManager.default.contents(atPath: environment.authorizedKeys.fileURL.path) ?? Data(), as: UTF8.self)
    }
}

private extension Result where Success == [String: Any], Failure == RelayAppCommandError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}

private final class FiredTools: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ name: String) { lock.withLock { values.append(name) } }
    var names: [String] { lock.withLock { values } }
}

/// A non-blocking Unix stream client that yields JSON objects by line.
private final class LineClient {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { close(fd) }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// The next line as a JSON object, polling so the main actor keeps serving the server's hops.
    @MainActor
    func object(timeout: Double = 5) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
