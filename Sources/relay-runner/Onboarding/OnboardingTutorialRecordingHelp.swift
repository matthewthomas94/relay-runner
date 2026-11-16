import Foundation

/// How macOS is set up to treat the Caps Lock key. Either setting stops a
/// normal press from turning Caps Lock on, so the tutorial never sees it.
struct CapsLockKeyboardConfiguration: Equatable {
    /// "Use the Caps Lock key to switch to and from ABC": a short press
    /// changes the input source instead of toggling Caps Lock.
    var switchesInputSource = false
    /// Keyboard > Modifier Keys maps Caps Lock to another key or No Action.
    var remapped = false

    /// HID usage page 7 (keyboard), usage 0x39 (Caps Lock).
    static let capsLockUsage: Int64 = 0x7_0000_0039
    static let modifierMappingPrefix = "com.apple.keyboard.modifiermapping"

    /// `romanSwitchState` is the private `TISRomanSwitchState` value. macOS
    /// stores it only once the user changes the setting, and the switch is on
    /// by default when more than one input source is enabled, so a missing
    /// value with several sources counts as switching.
    static func switchesInputSource(romanSwitchState: Int?,
                                    enabledInputSources: [[String: Any]]) -> Bool {
        let selectable = enabledInputSources.filter { source in
            let kind = source["InputSourceKind"] as? String
            return kind == "Keyboard Layout" || kind == "Keyboard Input Method"
        }
        guard selectable.count > 1 else { return false }
        return romanSwitchState != 0
    }

    static func remapped(mappings: [[String: Any]]) -> Bool {
        mappings.contains { mapping in
            guard let source = (mapping["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.int64Value,
                  source == capsLockUsage else { return false }
            let destination = (mapping["HIDKeyboardModifierMappingDst"] as? NSNumber)?.int64Value
            return destination != capsLockUsage
        }
    }

    /// Reads the live preferences. Mappings set only through `hidutil`
    /// (for example by Karabiner) are not visible here.
    static func current() -> CapsLockKeyboardConfiguration {
        let anyApp = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let hiToolbox = "com.apple.HIToolbox" as CFString
        let romanKey = "TISRomanSwitchState" as CFString
        let romanSwitchState =
            (CFPreferencesCopyValue(romanKey, anyApp, user, kCFPreferencesAnyHost) as? NSNumber)?.intValue
            ?? (CFPreferencesCopyAppValue(romanKey, hiToolbox) as? NSNumber)?.intValue
        let sources = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString, hiToolbox)
            as? [[String: Any]] ?? []

        var mappings: [[String: Any]] = []
        for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
            let keys = CFPreferencesCopyKeyList(anyApp, user, host) as? [String] ?? []
            for key in keys where key.hasPrefix(modifierMappingPrefix) {
                mappings += CFPreferencesCopyValue(key as CFString, anyApp, user, host)
                    as? [[String: Any]] ?? []
            }
        }
        return CapsLockKeyboardConfiguration(
            switchesInputSource: switchesInputSource(
                romanSwitchState: romanSwitchState,
                enabledInputSources: sources
            ),
            remapped: remapped(mappings: mappings)
        )
    }
}

/// One reading of everything the tutorial's recording step depends on.
/// Carries no key contents: only Caps Lock's on/off state and an event count.
struct OnboardingTutorialRecordingProbe: Equatable {
    var speech: SetupRuntimeReadiness = .ready
    var microphone: PermissionStatus = .granted
    /// Input Monitoring preflight, the grant the key monitors run on
    /// (RR-517; Accessibility doesn't count). A preflight answer only: RR-517
    /// saw "allowed" with no visible grant, so the watch still requires Caps
    /// Lock activity.
    var keyboardAccess: PermissionStatus = .granted
    var microphoneCaptureReady = true
    var capsLockOn = false
    var capsLockKeyEvents = 0
    var capsLock = CapsLockKeyboardConfiguration()

    var logSummary: String {
        "speech=\(Self.speechLabel(speech)) microphone=\(microphone) " +
        "keyboardAccess=\(keyboardAccess) captureReady=\(microphoneCaptureReady) " +
        "capsLockSwitchesInputSource=\(capsLock.switchesInputSource) capsLockRemapped=\(capsLock.remapped)"
    }

    private static func speechLabel(_ speech: SetupRuntimeReadiness) -> String {
        switch speech {
        case .notStarted: return "notStarted"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

/// Watches the recording step for the two ways Caps Lock can fail: it was
/// pressed and recording didn't start, or no Caps Lock activity arrived at all.
struct OnboardingTutorialRecordingWatch {
    enum Symptom: String, Equatable {
        case noCapsLockEvents
        case pressedWithoutRecording
        /// The global key monitor hasn't attached yet (RR-517).
        case keyMonitorNotAttached
    }

    static let pressGrace: TimeInterval = 3
    static let silenceGrace: TimeInterval = 10

    let startedAt: Date
    private var lastCapsLockOn: Bool
    private var lastKeyEvents: Int
    private(set) var firstPressAt: Date?

    init(startedAt: Date, baseline: OnboardingTutorialRecordingProbe) {
        self.startedAt = startedAt
        lastCapsLockOn = baseline.capsLockOn
        lastKeyEvents = baseline.capsLockKeyEvents
    }

    /// Returns the symptom once its grace period has passed, otherwise nil.
    mutating func observe(_ probe: OnboardingTutorialRecordingProbe, now: Date) -> Symptom? {
        if probe.capsLockOn != lastCapsLockOn || probe.capsLockKeyEvents != lastKeyEvents {
            firstPressAt = firstPressAt ?? now
        }
        lastCapsLockOn = probe.capsLockOn
        lastKeyEvents = probe.capsLockKeyEvents
        if let firstPressAt {
            return now.timeIntervalSince(firstPressAt) >= Self.pressGrace ? .pressedWithoutRecording : nil
        }
        return now.timeIntervalSince(startedAt) >= Self.silenceGrace ? .noCapsLockEvents : nil
    }
}

/// The short reason and one-click fix the recording step shows.
struct OnboardingTutorialRecordingHelp: Equatable {
    enum Reason: String, Equatable {
        case microphoneNotGranted
        case speechModelFailed
        case speechModelPreparing
        case capsLockSwitchesInputSource
        case capsLockRemapped
        case keyboardAccessMissing
        case microphoneUnavailable
        /// Preflight says key monitoring is allowed, yet no Caps Lock activity
        /// arrived, so it isn't treated as working.
        case keyMonitoringUnverified
        /// macOS hasn't let the global key monitor attach yet (RR-517).
        case keyMonitorPending
        case recordingDidNotStart
    }

    enum SettingsPane: String, Equatable {
        case microphone
        case accessibility
        case inputMonitoring
        case keyboard
        case sound

        var url: URL {
            switch self {
            case .microphone:
                return URL(string: PermissionKind.microphone.settingsURL)!
            case .accessibility:
                return URL(string: PermissionKind.accessibility.settingsURL)!
            case .inputMonitoring:
                return URL(string: PermissionKind.inputMonitoring.settingsURL)!
            case .keyboard:
                return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            case .sound:
                return URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
            }
        }
    }

    enum Fix: Equatable {
        case retrySpeechSetup
        case openSettings(SettingsPane)

        var title: String {
            switch self {
            case .retrySpeechSetup: return "Retry Speech Setup"
            case .openSettings(.microphone): return "Open Microphone Settings"
            case .openSettings(.accessibility): return "Open Accessibility Settings"
            case .openSettings(.inputMonitoring): return "Open Input Monitoring Settings"
            case .openSettings(.keyboard): return "Open Keyboard Settings"
            case .openSettings(.sound): return "Open Sound Settings"
            }
        }
    }

    static let keyMonitorWaitingMessage =
        "Waiting for macOS to apply the permission. This can take a minute."

    /// The recording step's waiting state while the key monitor can't attach.
    static let keyMonitorWaiting = OnboardingTutorialRecordingHelp(
        symptom: .keyMonitorNotAttached,
        reason: .keyMonitorPending,
        message: keyMonitorWaitingMessage,
        fix: .openSettings(.inputMonitoring)
    )

    static let startRecordingTitle = "Start recording"
    static let stopRecordingTitle = "Stop and send"

    let symptom: OnboardingTutorialRecordingWatch.Symptom
    let reason: Reason
    let message: String
    let fix: Fix?

    static func diagnose(_ symptom: OnboardingTutorialRecordingWatch.Symptom,
                         probe: OnboardingTutorialRecordingProbe) -> OnboardingTutorialRecordingHelp {
        func help(_ reason: Reason, _ message: String, _ fix: Fix?) -> OnboardingTutorialRecordingHelp {
            OnboardingTutorialRecordingHelp(symptom: symptom, reason: reason, message: message, fix: fix)
        }
        if symptom == .keyMonitorNotAttached { return keyMonitorWaiting }
        if probe.microphone != .granted {
            return help(.microphoneNotGranted,
                        "Relay Runner can't use the microphone yet.",
                        .openSettings(.microphone))
        }
        switch probe.speech {
        case .failed:
            return help(.speechModelFailed,
                        "Speech recognition couldn't start, so Caps Lock can't record yet.",
                        .retrySpeechSetup)
        case .preparing, .notStarted:
            return help(.speechModelPreparing,
                        "Speech recognition is still getting ready. The first time can take a few minutes.",
                        nil)
        case .ready:
            break
        }
        if probe.capsLock.switchesInputSource {
            return help(.capsLockSwitchesInputSource,
                        "Caps Lock is set to switch input sources, so a short press changes your keyboard language. Hold it for a moment, or turn that off in Keyboard Settings.",
                        .openSettings(.keyboard))
        }
        if probe.capsLock.remapped {
            return help(.capsLockRemapped,
                        "Caps Lock is remapped in Keyboard Settings > Modifier Keys.",
                        .openSettings(.keyboard))
        }
        // Caps Lock recording reads the key's state directly, so it never needs
        // Accessibility; only a Caps Lock that was never seen points at access.
        switch symptom {
        case .keyMonitorNotAttached:
            return keyMonitorWaiting
        case .pressedWithoutRecording:
            if !probe.microphoneCaptureReady {
                return help(.microphoneUnavailable,
                            "Caps Lock worked, but the microphone didn't open. Check your input device.",
                            .openSettings(.sound))
            }
            return help(.recordingDidNotStart,
                        "Caps Lock was pressed but recording didn't start. Click Start recording instead.",
                        nil)
        case .noCapsLockEvents:
            if probe.keyboardAccess != .granted {
                return help(.keyboardAccessMissing,
                            "Relay Runner hasn't seen Caps Lock. Turn Relay Runner on in Privacy & Security > Input Monitoring, or click Start recording.",
                            .openSettings(.inputMonitoring))
            }
            return help(.keyMonitoringUnverified,
                        "macOS says Relay Runner can see the keyboard, but no Caps Lock press has reached it. Check Relay Runner is on in Privacy & Security > Input Monitoring, or click Start recording.",
                        .openSettings(.inputMonitoring))
        }
    }
}

/// Buttons on the recording steps: the click fallback and the help's fix.
struct OnboardingTutorialRecordingActions {
    let toggleRecording: () -> Void
    let fix: (() -> Void)?
}
