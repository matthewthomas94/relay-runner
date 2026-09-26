import AppKit
import SwiftUI

struct CustomVoiceSettingsSection: View {
    @Binding var config: TtsConfig
    @Bindable var appState: AppState
    @Bindable var preview: VoicePreviewController
    private let store = CustomVoiceStore()
    @State private var profiles: [CustomVoiceProfile] = []
    @State private var selectedID = ""
    @State private var samples: [Float] = []
    @State private var sampleStart = 0.0
    @State private var sampleLength = 8.0
    @State private var name = ""
    @State private var affirmed = false
    @State private var staged: CustomVoiceProfile?
    @State private var importing = false
    @State private var importGeneration = UUID()
    @State private var error: String?
    @State private var runtimeReady = false
    @State private var deleteTarget: CustomVoiceProfile?
    @State private var renameTarget: CustomVoiceProfile?
    @State private var renameName = ""
    @State private var recorder = VoiceSampleRecorder()

    private var selected: CustomVoiceProfile? { profiles.first { $0.id == selectedID } }
    private var audioActionsEnabled: Bool { !preview.isBusy && !recorder.isBusy && !appState.settingsAudioBusy }
    private var duration: Double { Double(samples.count) / 24_000 }
    private var clipped: Bool { samples.contains { abs($0) >= 0.99 } }
    private var selectedSamples: [Float] {
        let start = min(samples.count, max(0, Int(sampleStart * 24_000)))
        let end = min(samples.count, start + Int(sampleLength * 24_000))
        return Array(samples[start..<end])
    }
    private func key(_ profile: CustomVoiceProfile) -> String {
        "\(profile.id):\(profile.content_hash):\((try? store.runtimeFingerprint()) ?? "missing"):\(config.voice):\(config.rate)"
    }

    var body: some View {
        SettingsSection("Custom Voices", badge: "Experimental") {
            SettingsRow {
                Text("Import a short recording to match a voice’s sound. Everything stays on this Mac. Pronunciation and accent still depend on the base voice above.")
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            SettingsControlRow(
                "Local cloning engine",
                description: runtimeReady
                    ? "Relay manages the cloning engine with its local support files. No separate manifest is needed."
                    : "Requires a separately provisioned local cloning runtime. The app download does not include the engine or models. Standard voices remain available."
            ) {
                SettingsInlineStatus(
                    text: runtimeReady ? "Ready" : "Not installed",
                    semanticColor: runtimeReady ? .success : .idle,
                    reservedWidth: 110
                )
            }

            if !profiles.isEmpty {
                SettingsDivider()
                SettingsControlRow(
                    "Saved voice",
                    description: "Preview before selecting. Save settings below to apply the selection."
                ) {
                    Picker("Saved voice", selection: $selectedID) {
                        Text("Choose a voice").tag("")
                        ForEach(profiles) { Text($0.name).tag($0.id) }
                    }
                }
                if let profile = selected {
                    SettingsRow {
                        SettingsActionButton(title: "Original", systemImage: "play.fill", isEnabled: audioActionsEnabled) {
                            playOriginal(profile)
                        }
                        SettingsActionButton(title: "Preview", systemImage: "waveform", isEnabled: audioActionsEnabled) {
                            preview.preview(voice: config.voice, rate: config.rate, profile: profile,
                                            key: key(profile), appState: appState)
                        }
                        SettingsActionButton(
                            title: "Use Voice", systemImage: "checkmark",
                            isEnabled: audioActionsEnabled && preview.successfulKey == key(profile)
                        ) {
                            do {
                                try store.acceptPreview(profile, runtimeID: store.runtimeFingerprint(), baseVoice: config.voice)
                                config.custom_voice_id = profile.id
                                appState.customVoiceNotice = nil
                                refresh()
                            } catch { self.error = "The reference or runtime changed. Preview this voice again before selecting it." }
                        }
                        SettingsActionButton(title: "Rename", systemImage: "pencil", isEnabled: audioActionsEnabled) {
                            renameTarget = profile
                            renameName = profile.name
                        }
                        SettingsActionButton(title: "Delete", systemImage: "trash", isEnabled: audioActionsEnabled) {
                            deleteTarget = profile
                        }
                    }
                }
            }
            if let id = config.custom_voice_id, !profiles.contains(where: { $0.id == id }) {
                SettingsRow {
                    Text("The selected voice is missing or damaged. Speech will use George; choose Standard or import it again.")
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                }
            }

            SettingsDivider()

            SettingsRow {
                SettingsActionButton(
                    title: importing ? "Importing…" : "Import Audio", systemImage: "square.and.arrow.down",
                    isEnabled: !importing && !preview.isBusy && !recorder.isBusy,
                    action: chooseAudio
                )
                SettingsActionButton(
                    title: samples.isEmpty ? "Record Sample" : "Retake Sample", systemImage: "mic",
                    isEnabled: !importing && audioActionsEnabled
                ) {
                    cancelDraft()
                    recorder.record(appState: appState) { audio in
                        samples = audio
                        sampleStart = 0
                        sampleLength = min(8, Double(audio.count) / 24_000)
                    }
                }
                if !samples.isEmpty || importing {
                    SettingsActionButton(title: "Cancel Import", systemImage: "xmark", action: cancelDraft)
                }
                if preview.isBusy {
                    SettingsActionButton(title: "Stop", systemImage: "stop.fill", action: preview.stop)
                }
            }
            if recorder.isBusy {
                SettingsDivider()
                SettingsRow {
                    Text("Recording reference: \(recorder.elapsed, specifier: "%.1f") / 10s")
                        .monospacedDigit()
                    Spacer(minLength: SettingsLayout.labelControlSpacing)
                    SettingsActionButton(title: "Stop Recording", systemImage: "stop.fill", action: recorder.stop)
                    SettingsActionButton(title: "Cancel", systemImage: "xmark", action: recorder.cancel)
                }
            }
            if !samples.isEmpty { draftEditor }
            if let recordingError = recorder.error {
                SettingsRow {
                    Text(recordingError)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                }
            }
            if let notice = appState.customVoiceNotice {
                SettingsRow {
                    Text(notice)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                }
            }
            if let error {
                SettingsRow {
                    Text(error)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onDisappear { cancelDraft() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in cancelDraft() }
        .onChange(of: appState.settingsAudioBusy) { _, busy in if busy { recorder.cancel() } }
        .onChange(of: appState.sttEngine.map(ObjectIdentifier.init)) { _, _ in recorder.cancel() }
        .onChange(of: selectedID) { _, _ in preview.invalidate() }
        .onChange(of: config.voice) { _, _ in discardStaged() }
        .onChange(of: config.rate) { _, _ in preview.invalidate() }
        .alert("Delete custom voice?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) { if let profile = deleteTarget { delete(profile) }; deleteTarget = nil }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text("This removes the managed reference, not the original recording or your backups. The selected voice will switch to George.") }
        .alert("Rename voice", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameName, prompt: Text("Name").foregroundColor(BoardDarkSurfaceStyle.placeholderText))
            Button("Save") {
                do { if let profile = renameTarget { try store.rename(profile.id, name: renameName) }; refresh() }
                catch { self.error = "Could not rename this voice. Use a name of 1–80 characters." }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var draftEditor: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            SettingsControlRow("Voice name") {
                TextField("Voice name", text: $name, prompt: Text("Voice name").foregroundColor(BoardDarkSurfaceStyle.placeholderText)).textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in discardStaged() }
            }

            SettingsDivider()

            SettingsStackedControlRow("Reference") {
                Text("\(sampleStart, specifier: "%.1f")s – \(sampleStart + sampleLength, specifier: "%.1f")s")
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    .monospacedDigit()
                if duration > sampleLength {
                    Slider(value: $sampleStart, in: 0...max(0.01, duration - sampleLength), step: 0.1)
                        .accessibilityLabel("Reference start time")
                        .onChange(of: sampleStart) { _, _ in discardStaged() }
                }
                Slider(value: $sampleLength, in: 5...max(5.01, min(10, duration)), step: 0.1)
                    .accessibilityLabel("Reference duration")
                    .onChange(of: sampleLength) { _, _ in sampleStart = min(sampleStart, max(0, duration - sampleLength)); discardStaged() }
                if clipped {
                    Text("This recording may be clipped. A cleaner reference can improve the result.")
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                }
            }

            SettingsDivider()

            SettingsRow {
                Toggle("I own this recording or have permission to use it for voice conversion.", isOn: $affirmed)
                    .controlSize(.small)
                    .onChange(of: affirmed) { _, _ in discardStaged() }
            }
            SettingsRow {
                SettingsActionButton(title: "Original", systemImage: "play.fill", isEnabled: audioActionsEnabled) {
                    preview.playOriginal(samples: selectedSamples, appState: appState)
                }
                SettingsActionButton(
                    title: "Generate Preview", systemImage: "waveform",
                    isEnabled: audioActionsEnabled && affirmed && !name.trimmingCharacters(in: .whitespaces).isEmpty && runtimeReady,
                    action: previewDraft
                )
                SettingsActionButton(
                    title: "Save Voice", systemImage: "checkmark",
                    isEnabled: audioActionsEnabled && staged != nil && preview.successfulKey == staged.map(key),
                    action: saveDraft
                )
            }
        }
    }

    private func refresh() {
        profiles = store.profiles()
        runtimeReady = (try? store.runtimeFingerprint()) != nil
        if selectedID.isEmpty { selectedID = config.custom_voice_id ?? "" }
    }

    private func chooseAudio() {
        appState.chooseCustomVoiceAudio { url in
            guard let url else { return }
            importAudio(url)
        }
    }

    private func importAudio(_ url: URL) {
        cancelDraft()
        error = nil
        importing = true
        let token = UUID()
        importGeneration = token
        Task {
            do {
                let audio = try await Task.detached(priority: .userInitiated) { try CustomVoiceStore.decode(url) }.value
                guard importGeneration == token else { return }
                samples = audio
                sampleStart = 0
                sampleLength = min(8, Double(audio.count) / 24_000)
            } catch {
                if importGeneration == token { self.error = CustomVoiceFailure.invalidAudio.localizedDescription }
            }
            if importGeneration == token { importing = false }
        }
    }

    private func playOriginal(_ profile: CustomVoiceProfile) {
        do { preview.playOriginal(try store.reference(profile.id), appState: appState) }
        catch { self.error = CustomVoiceFailure.invalidProfile.localizedDescription }
    }

    private func previewDraft() {
        discardStaged()
        do {
            let profile = try store.createDraft(samples: selectedSamples, name: name, baseVoice: config.voice, affirmed: affirmed)
            staged = profile
            preview.preview(voice: config.voice, rate: config.rate, profile: profile, draft: true,
                            key: key(profile), appState: appState)
        } catch { self.error = error.localizedDescription }
    }

    private func saveDraft() {
        guard let profile = staged, preview.successfulKey == key(profile) else { return }
        do {
            _ = try store.saveDraft(profile.id)
            staged = nil
            samples = []
            affirmed = false
            profiles = store.profiles()
            selectedID = profile.id
            // Saving does not silently select it or change persisted settings.
        } catch { self.error = "Could not save the private reference. Try importing it again." }
    }

    private func discardStaged() {
        preview.invalidate()
        if let profile = staged { try? store.delete(profile.id, draft: true) }
        staged = nil
    }

    private func cancelDraft() {
        recorder.cancel()
        importGeneration = UUID()
        importing = false
        discardStaged()
        samples = []
        affirmed = false
    }

    private func delete(_ profile: CustomVoiceProfile) {
        preview.invalidate()
        do {
            try store.delete(profile.id)
            if config.custom_voice_id == profile.id { config.custom_voice_id = nil; config.voice = "bm_george" }
            if appState.config.tts.custom_voice_id == profile.id {
                var updated = appState.config
                updated.tts.custom_voice_id = nil
                updated.tts.voice = "bm_george"
                appState.saveConfig(updated)
            }
            SocketClient.bridgeSend("reload")
            selectedID = ""
            refresh()
        } catch { self.error = "Could not delete this managed voice. No original recording was removed." }
    }
}
