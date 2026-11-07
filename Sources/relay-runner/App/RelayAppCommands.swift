import Foundation
import RelayRemoteProtocol

struct RelayAppCommandError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A surface `navigate` can show (RR-459).
enum RelayAppDestination: Equatable {
    case workspace
    case notetaker
    case terminal
    case settings(SettingsCategory?)
}

/// What Relay App's commands need from the app beyond the session control and
/// the Relay Remote controller. `AppState` supplies the live closures; tests inject fakes.
struct RelayAppCommandHost {
    /// `app` (version, build), `permissions` and `relay_remote` (Remote mode), JSON-ready.
    var status: () -> [String: Any]
    /// Shows a surface the way the session wheel does. Returns why it could not, or nil.
    var navigate: (RelayAppDestination) -> String?
    var config: () -> AppConfig
    /// `AppState.saveConfig`, the Settings Save path.
    var saveConfig: (AppConfig) -> Void
    /// Browses a registered project's board as `activate_project` does; never starts or focuses a session.
    var selectProject: @MainActor (_ projectID: String) async -> Result<String, RelayAppCommandError>
    var keepAwakeState: () -> KeepAwakeState
    /// `KeepAwakeController.toggle()`; false when a pending change ignores it.
    var toggleKeepAwake: () -> Bool
    /// False once the app that supplies these closures is gone; every command then refuses.
    var isAvailable: () -> Bool = { true }
}

/// The app side of `RelayAppCommandHost`, held weakly so a command arriving
/// while Relay Runner quits reports that instead of a default value.
protocol RelayAppCommandOwner: AnyObject {
    var relayAppStatus: [String: Any] { get }
    /// Why the surface could not be shown, or nil once it is.
    func openRelayAppDestination(_ destination: RelayAppDestination) -> String?
    var relayAppConfig: AppConfig { get }
    func saveRelayAppConfig(_ config: AppConfig)
    @MainActor func selectRelayAppProject(_ projectID: String) async -> Result<String, RelayAppCommandError>
    var relayAppKeepAwakeState: KeepAwakeState { get }
    func toggleRelayAppKeepAwake() -> Bool
}

extension RelayAppCommandHost {
    static let quittingMessage = "Relay Runner is quitting."

    /// Closures over a weakly held owner. A gone owner is the only quitting
    /// case: `navigate`'s nil still means the surface opened.
    init(weaklyHolding owner: some RelayAppCommandOwner) {
        self.init(
            status: { [weak owner] in owner?.relayAppStatus ?? [:] },
            navigate: { [weak owner] destination in
                guard let owner else { return Self.quittingMessage }
                return owner.openRelayAppDestination(destination)
            },
            config: { [weak owner] in owner?.relayAppConfig ?? AppConfig() },
            saveConfig: { [weak owner] in owner?.saveRelayAppConfig($0) },
            selectProject: { [weak owner] projectID in
                guard let owner else { return .failure(RelayAppCommandError(Self.quittingMessage)) }
                return await owner.selectRelayAppProject(projectID)
            },
            keepAwakeState: { [weak owner] in owner?.relayAppKeepAwakeState ?? .off },
            toggleKeepAwake: { [weak owner] in owner?.toggleRelayAppKeepAwake() ?? false },
            isAvailable: { [weak owner] in owner != nil }
        )
    }
}

/// Relay App (RR-459): the app's first-party command surface, reached through
/// `app_command` lines on the session-control socket from `relay-app-mcp`.
/// Each command returns structured JSON. Every command is idempotent or says
/// in its result what it changed; `end_session` and `relay_remote_unpair`
/// need `confirm: true`. Pairing is driven through `RelayRemoteController`
/// exactly as the Settings page drives it. Main-actor only.
@MainActor
final class RelayAppCommands {
    static let commandNames = [
        "app_status", "navigate", "get_settings", "set_settings",
        "list_projects", "select_project", "start_session", "end_session",
        "relay_remote_devices", "relay_remote_unpair", "relay_remote_begin_pairing",
        "relay_remote_pending_approval", "relay_remote_approve", "relay_remote_deny",
        "keep_awake",
    ]

    static let settingsPages: [String: SettingsCategory] = [
        "permissions": .permissions,
        "speech_to_text": .speechToText,
        "text_to_speech": .textToSpeech,
        "general": .general,
        "awareness": .awareness,
        "relay_remote": .relayRemote,
    ]

    private let host: RelayAppCommandHost
    private let session: RelaySessionControl
    private let remote: RelayRemoteController
    /// How long a pairing step may take to settle before its state is reported.
    var settleTimeout: TimeInterval = 10

    init(host: RelayAppCommandHost, session: RelaySessionControl, remote: RelayRemoteController) {
        self.host = host
        self.session = session
        self.remote = remote
    }

    /// One `app_command` line: `{"type":"app_command","id":…,"command":…,"arguments":{…}}`.
    func handle(_ object: [String: Any]) async -> Result<[String: Any], RelayAppCommandError> {
        guard let command = object["command"] as? String else {
            return .failure(RelayAppCommandError("app_command needs a command."))
        }
        guard let arguments = (object["arguments"] ?? [String: Any]()) as? [String: Any] else {
            return .failure(RelayAppCommandError("app_command arguments must be an object."))
        }
        return await run(command, arguments)
    }

    func run(_ command: String, _ arguments: [String: Any]) async -> Result<[String: Any], RelayAppCommandError> {
        guard host.isAvailable() else { return .failure(RelayAppCommandError(RelayAppCommandHost.quittingMessage)) }
        do {
            return .success(try await perform(command, Arguments(command: command, values: arguments)))
        } catch let error as RelayAppCommandError {
            return .failure(error)
        } catch {
            return .failure(RelayAppCommandError(error.localizedDescription))
        }
    }

    /// The `app_result` line answering request `id`.
    nonisolated static func encode(id: String, _ result: Result<[String: Any], RelayAppCommandError>) -> Data {
        var object: [String: Any] = ["type": "app_result", "id": id]
        switch result {
        case .success(let value):
            object["ok"] = true
            object["result"] = value
        case .failure(let error):
            object["ok"] = false
            object["error"] = error.message
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":"The result could not be encoded.","ok":false,"type":"app_result"}"#.utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Commands

    private func perform(_ command: String, _ a: Arguments) async throws -> [String: Any] {
        switch command {
        case "app_status":
            try a.only([])
            return status()
        case "navigate":
            try a.only(["destination", "settings_page"])
            return try navigate(a)
        case "get_settings":
            try a.only([])
            return ["settings": RelayAppSettings.json(host.config()), "read_only": RelayAppSettings.readOnly.sorted()]
        case "set_settings":
            try a.only(["settings"])
            guard let patch = a.values["settings"] as? [String: Any] else {
                throw RelayAppCommandError(#"set_settings needs settings, an object such as {"tts": {"rate": 1.2}}."#)
            }
            let current = host.config()
            let (next, changed) = try RelayAppSettings.applying(patch, to: current)
            if next != current { host.saveConfig(next) }
            return ["changed": changed, "settings": RelayAppSettings.json(host.config())]
        case "list_projects":
            try a.only([])
            return Self.json(session.perform(.listProjects))
        case "select_project":
            try a.only(["project_id"])
            let id = try a.requiredString("project_id")
            switch await host.selectProject(id) {
            case .success(let message): return ["message": message, "session": Self.json(session.perform(.state))]
            case .failure(let error): throw error
            }
        case "start_session":
            try a.only(["project_id"])
            let state = session.perform(.start, projectID: try a.requiredString("project_id"))
            if let error = state.error { throw RelayAppCommandError(error) }
            return Self.json(state)
        case "end_session":
            try a.only(["confirm"])
            try a.requireConfirm("end_session ends every running session")
            let running = session.perform(.state).session != .noSession
            return ["ended": running, "session": Self.json(session.perform(.stop))]
        case "relay_remote_devices":
            try a.only([])
            await remote.refresh()
            return remoteDevices()
        case "relay_remote_unpair":
            try a.only(["device_id", "confirm"])
            return try unpair(a)
        case "relay_remote_begin_pairing":
            try a.only([])
            return try await beginPairing()
        case "relay_remote_pending_approval":
            try a.only([])
            return pendingApproval()
        case "relay_remote_approve":
            try a.only(["restrict_to_network"])
            guard let restrict = try a.bool("restrict_to_network") else {
                throw RelayAppCommandError("relay_remote_approve needs restrict_to_network: true limits the device to this Mac's home network and Tailscale; false allows it from anywhere.")
            }
            return try await decide(allow: true, restrictToNetwork: restrict)
        case "relay_remote_deny":
            try a.only([])
            return try await decide(allow: false, restrictToNetwork: false)
        case "keep_awake":
            try a.only(["on"])
            guard let on = try a.bool("on") else { throw RelayAppCommandError("keep_awake needs on: true or false.") }
            return try keepAwake(on: on)
        default:
            throw RelayAppCommandError("Unknown Relay App command '\(command)'. Commands: \(Self.commandNames.joined(separator: ", ")).")
        }
    }

    private func status() -> [String: Any] {
        remote.reloadDevices()
        var result = host.status()
        result["session"] = Self.json(session.perform(.state))
        var remoteInfo = result["relay_remote"] as? [String: Any] ?? [:]
        remoteInfo["paired_devices"] = remote.devices.count
        remoteInfo["remote_login"] = Self.name(remote.remoteLogin)
        remoteInfo["pairing"] = Self.name(remote.phase)
        result["relay_remote"] = remoteInfo
        result["keep_awake"] = Self.json(host.keepAwakeState())
        return result
    }

    private func navigate(_ a: Arguments) throws -> [String: Any] {
        let name = try a.requiredString("destination")
        let page = try a.string("settings_page")
        let destination: RelayAppDestination
        switch name {
        case "workspace": destination = .workspace
        case "notetaker": destination = .notetaker
        case "terminal": destination = .terminal
        case "settings":
            destination = .settings(try page.map { page in
                guard let category = Self.settingsPages[page] else {
                    throw RelayAppCommandError("Unknown settings_page '\(page)'. Pages: \(Self.settingsPages.keys.sorted().joined(separator: ", ")).")
                }
                return category
            })
        default:
            throw RelayAppCommandError("Unknown destination '\(name)'. Destinations: workspace, notetaker, terminal, settings.")
        }
        if page != nil, name != "settings" {
            throw RelayAppCommandError("settings_page applies only to destination settings.")
        }
        if let reason = host.navigate(destination) { throw RelayAppCommandError(reason) }
        var result: [String: Any] = ["opened": name]
        if let page { result["settings_page"] = page }
        return result
    }

    // MARK: Relay Remote

    private func remoteDevices() -> [String: Any] {
        [
            "remote_login": Self.name(remote.remoteLogin),
            "devices": remote.devices.map(Self.json),
        ]
    }

    private func unpair(_ a: Arguments) throws -> [String: Any] {
        let id = try a.requiredString("device_id")
        try a.requireConfirm("relay_remote_unpair removes the device's access to this Mac")
        remote.reloadDevices()
        guard let device = remote.devices.first(where: { $0.id == id }) else {
            throw RelayAppCommandError("No paired device has id '\(id)'. Call relay_remote_devices for the list.")
        }
        remote.unpair(device)
        if remote.devices.contains(where: { $0.id == id }) {
            throw RelayAppCommandError(remote.errorMessage ?? "Relay Runner could not unpair \(device.name).")
        }
        return ["unpaired": id, "devices": remote.devices.map(Self.json)]
    }

    private func beginPairing() async throws -> [String: Any] {
        switch remote.phase {
        case .showingCode(let code):
            return Self.json(code, started: false)
        case .confirming:
            throw RelayAppCommandError("A device is already waiting for approval. Call relay_remote_pending_approval, then relay_remote_approve or relay_remote_deny.")
        case .starting:
            break
        case .idle, .finished:
            remote.dismissOutcome()
            remote.beginPairing()
        }
        await settle { phase in
            if case .showingCode = phase { return true }
            return phase == .idle
        }
        guard case .showingCode(let code) = remote.phase else {
            throw RelayAppCommandError(remote.errorMessage ?? "Pairing did not start within \(Int(settleTimeout)) seconds.")
        }
        var result = Self.json(code, started: true)
        // The phone scans the code, so show it where the Settings page draws it.
        if let reason = host.navigate(.settings(.relayRemote)) {
            result["qr_code"] = "Not shown: \(reason) Open Settings > Relay Remote to show it."
        }
        return result
    }

    private func pendingApproval() -> [String: Any] {
        guard case .confirming(let request) = remote.phase else {
            var result: [String: Any] = ["pending": false, "pairing": Self.name(remote.phase)]
            if case .finished(let outcome) = remote.phase { result.merge(Self.json(outcome)) { $1 } }
            return result
        }
        return [
            "pending": true,
            "device_id": request.deviceID,
            "device_name": request.deviceName,
            "fingerprint": request.fingerprint,
        ]
    }

    private func decide(allow: Bool, restrictToNetwork: Bool) async throws -> [String: Any] {
        guard case .confirming(let request) = remote.phase else {
            var reason = "No device is waiting for approval (pairing is \(Self.name(remote.phase)))."
            if case .finished(let outcome) = remote.phase { reason += " The last attempt ended \(Self.json(outcome)["outcome"] ?? "")." }
            throw RelayAppCommandError(reason)
        }
        if allow { remote.restrictToNetwork = restrictToNetwork }
        remote.decide(allow: allow)
        await settle { phase in
            if case .finished = phase { return true }
            return phase == .idle
        }
        guard case .finished(let outcome) = remote.phase else {
            throw RelayAppCommandError("The pairing decision did not finish within \(Int(settleTimeout)) seconds; check relay_remote_pending_approval.")
        }
        if case .failed(let message) = outcome { throw RelayAppCommandError(message) }
        var result = Self.json(outcome)
        result["device_id"] = request.deviceID
        if let device = remote.devices.first(where: { $0.id == request.deviceID }) {
            result["device"] = Self.json(device)
        }
        return result
    }

    private func settle(until done: (RelayRemoteController.Phase) -> Bool) async {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while !done(remote.phase), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Keep Awake

    private func keepAwake(on: Bool) throws -> [String: Any] {
        let before = host.keepAwakeState()
        var changed = false
        switch (on, before) {
        case (_, .enabling), (_, .disabling):
            break // Pending: a toggle is ignored until it settles, so report it.
        case (true, .on), (true, .awaitingApproval), (false, .off), (false, .failed):
            break
        case (true, .restoreNeeded):
            throw RelayAppCommandError("Relay Runner must restore system sleep before Keep Awake can turn on. Call keep_awake with on: false first.")
        default:
            changed = host.toggleKeepAwake()
        }
        var result = Self.json(host.keepAwakeState())
        result["changed"] = changed
        return result
    }

    // MARK: JSON

    static func json(_ state: SessionState) -> [String: Any] {
        guard let line = try? FrameCodec.encode(.sessionState(state)),
              var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [:] }
        object["type"] = nil
        return object
    }

    static func json(_ state: KeepAwakeState) -> [String: Any] {
        let name: String
        switch state {
        case .off: name = "off"
        case .enabling: name = "enabling"
        case .awaitingApproval: name = "awaiting_approval"
        case .on: name = "on"
        case .disabling: name = "disabling"
        case .failed: name = "failed"
        case .restoreNeeded: name = "restore_needed"
        }
        return [
            "state": name,
            "on": state.isOn,
            "pending": state.isPending || state == .awaitingApproval,
            "status": state.status,
        ]
    }

    static func json(_ device: RelayRemoteController.Device) -> [String: Any] {
        [
            "device_id": device.id,
            "name": device.name,
            "fingerprint": device.fingerprint,
            "restricted_to_network": device.restrictedToNetwork,
        ]
    }

    static func json(_ outcome: RelayRemotePairingOutcome) -> [String: Any] {
        switch outcome {
        case .paired(let name): return ["outcome": "paired", "device_name": name]
        case .denied: return ["outcome": "denied"]
        case .expired: return ["outcome": "expired"]
        case .cancelled: return ["outcome": "cancelled"]
        case .failed(let message): return ["outcome": "failed", "error": message]
        }
    }

    /// The payload's non-secret fields; the pairing key and token stay in the QR code.
    static func json(_ code: RelayRemoteController.PairingCode, started: Bool) -> [String: Any] {
        [
            "pairing": "showing_code",
            "started": started,
            "pairing_id": code.details.pairingID,
            "user": code.details.user,
            "hosts": code.details.hosts,
            "port": code.details.port,
            "expires_at": ISO8601DateFormatter().string(from: code.expiresAt),
            "expires_in_seconds": max(0, Int(code.expiresAt.timeIntervalSinceNow)),
            "qr_code": "Shown on Settings > Relay Remote. Scan it with the Relay Remote app; its one-time pairing key and token are never returned here.",
        ]
    }

    nonisolated static func permissions(_ status: (PermissionKind) -> PermissionStatus) -> [String: String] {
        var result: [String: String] = [:]
        for kind in PermissionKind.allCases {
            let key: String
            switch kind {
            case .microphone: key = "microphone"
            case .accessibility: key = "accessibility"
            case .inputMonitoring: key = "input_monitoring"
            case .screenRecording: key = "screen_recording"
            case .camera: key = "camera"
            }
            switch status(kind) {
            case .granted: result[key] = "granted"
            case .denied: result[key] = "denied"
            case .notDetermined: result[key] = "not_determined"
            case .restricted: result[key] = "restricted"
            }
        }
        return result
    }

    static func name(_ login: RelayRemoteController.RemoteLoginState) -> String {
        switch login {
        case .checking: return "checking"
        case .available: return "available"
        case .unavailable: return "unavailable"
        }
    }

    static func name(_ phase: RelayRemoteController.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .showingCode: return "showing_code"
        case .confirming: return "awaiting_approval"
        case .finished: return "finished"
        }
    }
}

/// A command's arguments, with strict key and type checks.
private struct Arguments {
    let command: String
    let values: [String: Any]

    func only(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            let accepted = allowed.isEmpty ? "no arguments" : allowed.sorted().joined(separator: ", ")
            throw RelayAppCommandError("\(command) does not accept \(unknown.joined(separator: ", ")); it takes \(accepted).")
        }
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayAppCommandError("\(key) must be a non-empty string.")
        }
        return text
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key) else { throw RelayAppCommandError("\(command) needs \(key).") }
        return text
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw RelayAppCommandError("\(key) must be true or false.")
        }
        return number.boolValue
    }

    func requireConfirm(_ effect: String) throws {
        guard try bool("confirm") == true else {
            throw RelayAppCommandError("Refused: \(effect). Pass confirm: true to proceed.")
        }
    }
}
