import Foundation
import IOKit.pwr_mgt

/// A `remote_device` event from the bridge's Relay Remote module. `active` and
/// `inactive` follow the phone's Remote mode switch (RR-454).
struct RemoteDeviceEvent: Equatable {
    enum Kind: String { case connected, active, inactive, disconnected }

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
            "Relay Remote mode active" as CFString,
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
/// A device whose Remote mode is on holds the keep-awake assertion; the one
/// that turned it on most recently holds the microphone gate. A device with
/// the mode off stays connected while the Mac keeps its microphone and voice.
/// A Mac user action takes the microphone back without changing the mode.
final class RelayRemoteDeviceSession {
    private let gate: RemoteMicrophoneGate
    private let keepAwake: RemoteKeepAwake
    private var connected: [String: String] = [:]
    private var order: [String] = []
    private var remoteMode: Set<String> = []
    private(set) var activeDeviceID: String?

    /// `Remote: <device name>` while a device's Remote mode is on, else nil.
    var statusLabel: String? {
        let id = activeDeviceID.flatMap { remoteMode.contains($0) ? $0 : nil }
            ?? order.last(where: { remoteMode.contains($0) })
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
            remoteMode.insert(event.deviceID)
            activeDeviceID = event.deviceID
            gate.suspendForRemoteDevice()
        case .inactive:
            connect(event)
            remoteMode.remove(event.deviceID)
            releaseMicrophone(from: event.deviceID)
        case .disconnected:
            guard connected[event.deviceID] != nil else { return }
            connected[event.deviceID] = nil
            order.removeAll { $0 == event.deviceID }
            remoteMode.remove(event.deviceID)
            releaseMicrophone(from: event.deviceID)
        }
        if remoteMode.isEmpty { keepAwake.release() } else { keepAwake.acquire() }
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
    }

    private func releaseMicrophone(from deviceID: String) {
        guard activeDeviceID == deviceID else { return }
        activeDeviceID = nil
        gate.resumeAfterRemoteDevice(preservingGesture: false)
    }
}
