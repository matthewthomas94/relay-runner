import CoreGraphics
import Foundation
import IOKit

/// The lid and the built-in display's brightness. Injected so tests never read the lid
/// or change this Mac's brightness.
struct KeepAwakeDisplay {
    /// nil on Macs without a lid or when the state can't be read.
    var lidClosed: () -> Bool?
    /// Calls `changed` on the main queue when the lid may have moved; the observation
    /// ends when the returned token is released.
    var observeLid: (_ changed: @escaping () -> Void) -> AnyObject?
    /// The built-in display's brightness, 0–1; nil without one or when unreadable.
    var brightness: () -> Float?
    var setBrightness: (Float) -> Bool

    static func live() -> KeepAwakeDisplay {
        KeepAwakeDisplay(
            lidClosed: KeepAwakeLidObserver.isLidClosed,
            observeLid: { KeepAwakeLidObserver(changed: $0) },
            brightness: { KeepAwakeBuiltInBrightness.shared?.read() },
            setBrightness: { KeepAwakeBuiltInBrightness.shared?.write($0) ?? false }
        )
    }
}

/// While Keep Awake is on and the lid is closed, the built-in display is set to zero
/// brightness so it doesn't stay lit. Opening the lid, turning Keep Awake off, or quitting
/// restores the brightness captured just before dimming; external displays are never
/// touched. Main thread only.
final class KeepAwakeLidDimmer {
    static let restoreAttempts = 6
    static let restoreRetryInterval: TimeInterval = 0.5

    /// Written before dimming and removed after a restore, so a crash is undone at the next launch.
    let recordURL: URL
    private let display: KeepAwakeDisplay
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    private var observation: AnyObject?
    private var active = false
    private var restoreGeneration = 0
    /// The brightness to restore; set only while Relay Runner has dimmed the display.
    private(set) var savedBrightness: Float?

    init(display: KeepAwakeDisplay, recordURL: URL,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         log: @escaping (String) -> Void) {
        self.display = display
        self.recordURL = recordURL
        self.schedule = schedule
        self.log = log
    }

    /// Follows Keep Awake's confirmed on state.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            observation = display.observeLid { [weak self] in self?.refresh() }
            refresh()
        } else {
            observation = nil
            restore()
        }
    }

    /// Re-reads the lid. An unreadable state is not evidence that it moved.
    func refresh() {
        guard active, let closed = display.lidClosed() else { return }
        if closed { dim() } else { restore() }
    }

    /// Launch: restores a brightness an interrupted session left dimmed.
    func recoverIfNeeded() {
        guard savedBrightness == nil, FileManager.default.fileExists(atPath: recordURL.path) else { return }
        guard let value = Self.validBrightness(try? String(contentsOf: recordURL, encoding: .utf8)) else {
            clearRecord()
            return
        }
        savedBrightness = value
        restore()
    }

    /// Quit and update relaunch: one immediate restore. A failure keeps the record for the next launch.
    func shutdown() {
        active = false
        observation = nil
        restoreGeneration += 1
        guard let saved = savedBrightness else { return }
        if display.setBrightness(saved) {
            savedBrightness = nil
            clearRecord()
        } else {
            log("Keep Awake couldn't restore the built-in display's brightness at quit")
        }
    }

    private func dim() {
        // A closed lid supersedes any restore still retrying.
        restoreGeneration += 1
        if savedBrightness == nil {
            // Without a valid reading there is nothing to restore later, so leave it alone.
            guard let current = display.brightness() else {
                log("Keep Awake couldn't read the built-in display's brightness; leaving it unchanged")
                return
            }
            guard current > 0 else { return }
            do {
                try String(current).write(to: recordURL, atomically: true, encoding: .utf8)
            } catch {
                log("Keep Awake couldn't record the built-in display's brightness; leaving it unchanged")
                return
            }
            savedBrightness = current
            log("Keep Awake dimming the built-in display while the lid is closed")
        }
        if !display.setBrightness(0) { log("Keep Awake couldn't dim the built-in display") }
    }

    private func restore() {
        restoreGeneration += 1
        attemptRestore(restoreGeneration, attempt: 1)
    }

    private func attemptRestore(_ generation: Int, attempt: Int) {
        guard generation == restoreGeneration, let saved = savedBrightness else { return }
        if display.setBrightness(saved) {
            savedBrightness = nil
            clearRecord()
            log("Keep Awake restored the built-in display's brightness")
        } else if attempt < Self.restoreAttempts {
            // The panel can take a moment to come back after the lid opens.
            schedule(Self.restoreRetryInterval) { [weak self] in self?.attemptRestore(generation, attempt: attempt + 1) }
        } else {
            log("Keep Awake couldn't restore the built-in display's brightness; it will retry at next launch")
        }
    }

    private func clearRecord() { try? FileManager.default.removeItem(at: recordURL) }

    static func validBrightness(_ text: String?) -> Float? {
        guard let text, let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0, value <= 1 else { return nil }
        return value
    }
}

/// IOPMrootDomain publishes the lid as `AppleClamshellState` and posts general-interest
/// messages when it changes; each message re-reads it, because many unrelated power events
/// arrive the same way.
final class KeepAwakeLidObserver {
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private let changed: () -> Void

    static func isLidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    init?(changed: @escaping () -> Void) {
        self.changed = changed
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        IONotificationPortSetDispatchQueue(port, .main)
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<KeepAwakeLidObserver>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return nil
        }
        self.port = port
    }

    deinit {
        if notification != 0 { IOObjectRelease(notification) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// The built-in panel's brightness through DisplayServices, the system framework behind
/// the brightness keys. It is private, so it is loaded at runtime; without it Keep Awake
/// leaves brightness unchanged.
final class KeepAwakeBuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static let shared = KeepAwakeBuiltInBrightness()

    private let get: GetBrightness
    private let set: SetBrightness

    private init?() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(framework, "DisplayServicesGetBrightness"),
              let set = dlsym(framework, "DisplayServicesSetBrightness") else { return nil }
        self.get = unsafeBitCast(get, to: GetBrightness.self)
        self.set = unsafeBitCast(set, to: SetBrightness.self)
    }

    /// The online list still includes the built-in panel after a closed lid removes it from the active list.
    static func builtInDisplay() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func read() -> Float? {
        guard let display = Self.builtInDisplay() else { return nil }
        var value: Float = -1
        guard get(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    func write(_ value: Float) -> Bool {
        guard let display = Self.builtInDisplay() else { return false }
        return set(display, value) == 0
    }
}
