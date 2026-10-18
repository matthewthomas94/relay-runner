import AppKit
import Darwin

/// AppKit does not deliver raw trackpad contacts system-wide. Load the optional
/// system touch reader at runtime; never intercept or synthesize OS gestures.
final class FourFingerTapMonitor {
    static let shared = FourFingerTapMonitor()
    var onTap: (() -> Void)?

    private typealias FrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateDevices = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    // Keep the framework loaded for the lifetime of its C callback functions.
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL
    )
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let framework, let address = dlsym(framework, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
    private let createDevices = symbol("MTDeviceCreateList", as: CreateDevices.self)
    private let register = symbol("MTRegisterContactFrameCallback", as: Register.self)
    private let unregister = symbol("MTUnregisterContactFrameCallback", as: Register.self)
    private let startDevice = symbol("MTDeviceStart", as: Start.self)
    private let stopDevice = symbol("MTDeviceStop", as: Stop.self)
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var gestures: [UInt: FourFingerTapGesture] = [:]
    private var listening = false
    private var suspended = false
    private var generation = 0

    private init() {}

    private static let callback: FrameCallback = { device, buffer, count, timestamp, _ in
        if let device {
            FourFingerTapMonitor.shared.receive(device: UInt(bitPattern: device), buffer: buffer,
                                                count: count, timestamp: timestamp)
        }
        return 0
    }

    func start() {
        guard refreshTimer == nil else { return }
        guard createDevices != nil, register != nil, unregister != nil,
              startDevice != nil, stopDevice != nil else {
            NSLog("[SessionWheel] Trackpad reader unavailable; the menu-bar entry remains available.")
            return
        }
        suspended = false
        refreshDevices()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.suspended = true
                self?.stopDevices()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.suspended = false
                self?.refreshDevices()
            })
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        stopDevices()
    }

    private func stopDevices() {
        lock.lock()
        listening = false
        generation += 1
        gestures.removeAll()
        lock.unlock()
        for device in devices {
            stopDevice?(device)
            unregister?(device, Self.callback)
        }
        devices.removeAll()
        deviceList = nil
    }

    private func refreshDevices() {
        guard !suspended, let list = createDevices?()?.takeRetainedValue() else { return }
        let current = (0..<CFArrayGetCount(list)).compactMap { index -> UnsafeMutableRawPointer? in
            guard let value = CFArrayGetValueAtIndex(list, index) else { return nil }
            // MTDeviceIsOpaqueSurface returns false for supported built-in
            // trackpads. Every device in this list can supply touch contacts.
            return UnsafeMutableRawPointer(mutating: value)
        }
        guard Set(current) != Set(devices) else { return }
        stopDevices()
        deviceList = list // Device pointers remain owned while callbacks are installed.
        devices = current
        lock.lock()
        listening = true
        lock.unlock()
        for device in devices {
            register?(device, Self.callback)
            startDevice?(device, 0)
        }
        NSLog("[SessionWheel] Listening on %ld multitouch device(s).", devices.count)
    }

    private func receive(device: UInt, buffer: UnsafeMutableRawPointer?, count: Int32, timestamp: Double) {
        let contacts = Self.decodeContacts(buffer, count: count)
        let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
        lock.lock()
        guard listening else { lock.unlock(); return }
        var gesture = gestures[device] ?? FourFingerTapGesture()
        let fires: Bool
        if let contacts {
            fires = gesture.update(contacts: contacts, at: timestamp, buttonDown: buttonDown)
        } else {
            gesture.cancel()
            fires = false
        }
        gestures[device] = gesture
        let generation = self.generation
        lock.unlock()
        if fires {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, !self.devices.isEmpty, !self.suspended else { return }
                self.onTap?()
            }
        }
    }

    /// MultitouchSupport's 96-byte contact ABI: identity at 16, phase at 20,
    /// normalized x/y at 32/36. Reject invalid records instead of guessing.
    static func decodeContacts(_ buffer: UnsafeMutableRawPointer?, count: Int32) -> [FourFingerTapGesture.Contact]? {
        guard (0...16).contains(count) else { return nil }
        guard count > 0 else { return [] }
        guard let buffer else { return nil }
        var contacts: [FourFingerTapGesture.Contact] = []
        for index in 0..<Int(count) {
            let record = buffer.advanced(by: index * 96)
            let phase = record.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            guard (0...7).contains(phase) else { return nil }
            guard phase == 3 || phase == 4 else { continue }
            let x = record.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let y = record.loadUnaligned(fromByteOffset: 36, as: Float.self)
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            contacts.append(.init(id: record.loadUnaligned(fromByteOffset: 16, as: Int32.self),
                                  position: CGPoint(x: CGFloat(x), y: CGFloat(y))))
        }
        guard Set(contacts.map(\.id)).count == contacts.count else { return nil }
        return contacts
    }
}
