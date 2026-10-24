import Foundation
import IOKit.pwr_mgt

/// A `remote_device` event from the bridge's Relay Remote module.
struct RemoteDeviceEvent: Equatable {
    enum Kind: String { case connected, active, disconnected }

    let kind: Kind
    let deviceID: String
    let deviceName: String

    /// The kind may ride in `state` (`source: remote_device`) or in `event`
    /// (`state: remote_device`). Anything else is not a remote device event.
    init?(_ json: [String: Any]) {
        let source = json["source"] as? String
        let state = json["state"] as? String
        let rawKind: String?
        if source == "remote_device" {
            rawKind = state
        } else if state == "remote_device" {
            rawKind = json["event"] as? String
        } else {
            return nil
        }
        guard let rawKind, let kind = Kind(rawValue: rawKind),
              let deviceID = json["device_id"] as? String, !deviceID.isEmpty
        else { return nil }
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = (json["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Phone"
    }

    init(_ kind: Kind, deviceID: String, deviceName: String) {
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

/// The Mac microphone gate the session drives.
protocol RemoteMicrophoneGate: AnyObject {
    func suspendForRemoteDevice()
    func resumeAfterRemoteDevice(preservingGesture: Bool)
}

extension STTEngine: RemoteMicrophoneGate {}

/// Holds a prevent-idle-sleep assertion; released explicitly.
protocol RemoteKeepAwake: AnyObject {
    func acquire()
    func release()
}

final class IOKitKeepAwake: RemoteKeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func acquire() {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Relay Remote device connected" as CFString,
            &assertionID
        )
        held = result == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit { release() }
}

/// Which phone is in control of voice input, and the keep-awake it needs.
/// Connected devices hold the assertion; an active one holds the microphone
/// gate. A Mac user action takes the microphone back without disconnecting.
final class RelayRemoteDeviceSession {
    private let gate: RemoteMicrophoneGate
    private let keepAwake: RemoteKeepAwake
    private var connected: [String: String] = [:]
    private var order: [String] = []
    private(set) var activeDeviceID: String?

    /// `Remote: <device name>` while a device is connected, else nil.
    var statusLabel: String? {
        let id = activeDeviceID.flatMap { connected[$0] != nil ? $0 : nil } ?? order.last
        return id.flatMap { connected[$0] }.map { "Remote: \($0)" }
    }

    var onChange: (() -> Void)?

    init(gate: RemoteMicrophoneGate, keepAwake: RemoteKeepAwake) {
        self.gate = gate
        self.keepAwake = keepAwake
    }

    func apply(_ event: RemoteDeviceEvent) {
        switch event.kind {
        case .connected:
            connect(event)
        case .active:
            connect(event)
            activeDeviceID = event.deviceID
            gate.suspendForRemoteDevice()
        case .disconnected:
            guard connected[event.deviceID] != nil else { return }
            connected[event.deviceID] = nil
            order.removeAll { $0 == event.deviceID }
            if activeDeviceID == event.deviceID {
                activeDeviceID = nil
                gate.resumeAfterRemoteDevice(preservingGesture: false)
            }
            if connected.isEmpty { keepAwake.release() }
        }
        onChange?()
    }

    /// Push-to-talk, wake word or a microphone click on the Mac.
    func userTookOver() {
        guard activeDeviceID != nil else { return }
        activeDeviceID = nil
        gate.resumeAfterRemoteDevice(preservingGesture: true)
        onChange?()
    }

    private func connect(_ event: RemoteDeviceEvent) {
        if connected[event.deviceID] == nil { order.append(event.deviceID) }
        connected[event.deviceID] = event.deviceName
        keepAwake.acquire()
    }
}
