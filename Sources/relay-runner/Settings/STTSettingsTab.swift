import SwiftUI

struct STTSettingsTab: View {
    @Binding var config: SttConfig
    var migrationState: STTPhononMigration.State?
    var onRetryMigration: () -> Void = {}
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsStack {
            SettingsSection("Recognition") {
                SettingsControlRow(
                    "STT Model",
                    description: "Applies to new recordings and notes."
                ) {
                    SettingsMenuPicker(
                        "STT Model",
                        selection: $config.model,
                        options: Self.modelOptions(operatingSystem: operatingSystem)
                    )
                    .help(Self.modelDescription(config, operatingSystem: operatingSystem))
                }

                if let migrationState, let message = Self.migrationMessage(migrationState) {
                    SettingsDivider()
                    SettingsControlRow("Phonon 2 Setup", description: message) {
                        if case .failed = migrationState {
                            SettingsActionButton(title: "Retry", systemImage: "arrow.clockwise") {
                                onRetryMigration()
                            }
                        }
                    }
                }

                SettingsDivider()

                SettingsControlRow(
                    "Input Device",
                    description: "Uses the current macOS input device until real device selection is available."
                ) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RelaySwap(Self.inputDeviceDisplayName(config.input_device), style: .text, alignment: .trailing) { deviceName in
                            Text(deviceName)
                                .font(AppTypography.font(.body))
                                .foregroundStyle(SettingsSurfaceColor.primaryText)
                        }
                        Text("Read-only")
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.mutedText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Input Device")
                    .accessibilityValue(Self.inputDeviceAccessibilityValue(config.input_device))
                }
            }

            if config.input_mode == "push_to_talk" || config.input_mode == "caps_lock_toggle" {
                SettingsSection("Activation") {
                    if config.input_mode == "push_to_talk" {
                        SettingsControlRow("Push-to-talk Key") {
                            KeyCaptureView(label: "Push-to-talk Key", showsLabel: false, value: $config.push_to_talk_key)
                        }
                        .transition(.relayReplacing(.element))
                    }

                    if config.input_mode == "caps_lock_toggle" {
                        SettingsControlRow("Activation Key") {
                            KeyCaptureView(label: "Activation Key", showsLabel: false, value: $config.activation_key)
                        }
                        .transition(.relayReplacing(.element))
                    }
                }
                .transition(.relayElement)
            }

            SettingsSection("Voice Activity") {
                SettingsControlRow("VAD Sensitivity") {
                    SettingsMenuPicker("VAD Sensitivity", selection: $config.vad_sensitivity, options: [
                        (label: "Low", value: "low"),
                        (label: "Medium", value: "medium"),
                        (label: "High", value: "high"),
                    ])
                }
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: config.input_mode)
    }

    /// Models this Mac can load. Phonon 2 needs macOS 15, so macOS 14 only
    /// offers Parakeet; the recommended label follows the OS-aware default.
    static func modelOptions(
        operatingSystem: OperatingSystemVersion,
        phononDefaultActive: Bool = STTModelPolicy.phononDefaultActive
    ) -> [(label: String, value: String)] {
        let recommended = STTModelPolicy.defaultModel(
            operatingSystem: operatingSystem,
            phononDefaultActive: phononDefaultActive
        )
        return STTModel.allCases
            .filter { STTModelPolicy.isSupported($0, operatingSystem: operatingSystem) }
            .map { model in
                let base: String
                switch model {
                case .phonon2: base = "Phonon 2 (English)"
                case .parakeetV2: base = "Parakeet v2 (English)"
                case .parakeetV3: base = "Parakeet v3 (multilingual, larger)"
                }
                return (label: model == recommended && model != .phonon2 ? "\(base), recommended" : base, value: model.rawValue)
            }
    }

    static func modelDescription(_ config: SttConfig, operatingSystem: OperatingSystemVersion) -> String {
        var parts = ["Changes apply from the next recording; a recording or note in progress keeps its model."]
        if !STTModelPolicy.isSupported(.phonon2, operatingSystem: operatingSystem) {
            parts.append("Phonon 2 (English) requires macOS 15 or later.")
        }
        if config.phonon_migration == SttConfig.PhononMigration.completed,
           config.model == STTModel.phonon2.rawValue,
           let previous = STTModel(rawValue: config.phonon_migration_previous_model) {
            parts.append("Switched automatically from \(previous.displayName). Choose \(previous.displayName) to roll back.")
        }
        return parts.joined(separator: " ")
    }

    static func migrationMessage(_ state: STTPhononMigration.State) -> String? {
        switch state {
        case .idle, .completed: return nil
        case .preparing(let status): return status
        case .waitingForIdle: return "Phonon 2 is ready. Switching after the current recording or note."
        case .failed(let message): return message
        }
    }

    static func inputDeviceDisplayName(_ device: String) -> String {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? "System Default" : trimmed
    }

    static func inputDeviceAccessibilityValue(_ device: String) -> String {
        "\(inputDeviceDisplayName(device)), read-only"
    }
}
