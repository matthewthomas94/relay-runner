import Foundation
import XCTest
@testable import relay_runner

final class ConfigManagerTests: XCTestCase {

    func testFreshConfigPersistsDefaultTTSRate() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)

        let loaded = manager.load()
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)

        XCTAssertEqual(loaded.tts.voice, "am_puck")
        XCTAssertEqual(loaded.tts.rate, 1.3)
        XCTAssertFalse(loaded.general.prevent_sleep_while_running)
        XCTAssertTrue(raw.contains("voice = \"am_puck\""))
        XCTAssertTrue(raw.contains("rate = 1.3"))
        XCTAssertTrue(raw.contains("prevent_sleep_while_running = false"))
    }

    func testWheelHapticsDefaultsOnForExistingConfigsAndPersistsOptOut() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "[general]\nauto_start = false\n".write(to: manager.configPath, atomically: true, encoding: .utf8)
        var config = manager.load()
        XCTAssertTrue(config.general.wheel_haptics)
        config.general.wheel_haptics = false
        try manager.save(config)
        XCTAssertFalse(manager.load().general.wheel_haptics)
        config.general.wheel_haptics = true
        try manager.save(config)
        XCTAssertTrue(manager.load().general.wheel_haptics)
    }

    func testMissingTTSRateFallsBackToDefaultWithoutRewritingExplicitValues() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [tts]
        voice = "bf_isabella"
        auto_play = true
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.tts.voice, "bf_isabella")
        XCTAssertTrue(loaded.tts.auto_play)
        XCTAssertEqual(loaded.tts.rate, 1.3)
    }

    func testVoiceOutsideStandardSetFallsBackToPuck() throws {
        XCTAssertEqual(TtsConfig.standardVoices, ["am_puck", "bm_george", "bf_isabella", "af_sky"])
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [tts]
        voice = "af_bella"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        XCTAssertEqual(manager.load().tts.voice, "am_puck")
    }

    func testExplicitTTSRateIsPreserved() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [tts]
        rate = 1.1
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.tts.rate, 1.1)
    }

    func testOrchestratorAndSubagentPolicyPersistThroughConfigManager() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.model = "fable"
        config.general.orchestrator_effort = "max"
        config.general.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
            config.general.orchestrator_effort,
            model: config.general.model
        )
        config.general.subagent_sizing_policy = .userDefault
        config.general.subagent_model = "strong"
        config.general.subagent_effort = "xhigh"
        config.general.messenger_enabled = false
        config.general.messenger_model = "sonnet"
        config.general.messenger_effort = "low"
        config.general.prevent_sleep_while_running = true

        try manager.save(config)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)
        let loaded = manager.load()

        XCTAssertTrue(raw.contains("orchestrator_effort = \"max\""))
        XCTAssertTrue(raw.contains("codex_reasoning_effort = \"default\""))
        XCTAssertTrue(raw.contains("subagent_sizing_policy = \"user_default\""))
        XCTAssertFalse(raw.contains("subagent_model"))
        XCTAssertFalse(raw.contains("subagent_effort"))
        XCTAssertTrue(raw.contains("messenger_enabled = false"))
        XCTAssertTrue(raw.contains("messenger_model = \"sonnet\""))
        XCTAssertTrue(raw.contains("prevent_sleep_while_running = true"))
        XCTAssertEqual(loaded.general.provider, .claude)
        XCTAssertEqual(loaded.general.model, "fable")
        XCTAssertEqual(loaded.general.orchestrator_effort, "max")
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .userDefault)
        XCTAssertEqual(loaded.general.subagent_model, GeneralConfig.defaultSubagentModel)
        XCTAssertEqual(loaded.general.subagent_effort, GeneralConfig.defaultSubagentEffort)
        XCTAssertFalse(loaded.general.messenger_enabled)
        XCTAssertEqual(loaded.general.messenger_model, "sonnet")
        XCTAssertEqual(loaded.general.messenger_effort, "low")
        XCTAssertTrue(loaded.general.prevent_sleep_while_running)
    }

    func testLegacyMessagePreviewFalseIsIgnoredAndNotSerialized() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [awareness]
        message_preview = false
        live_transcription = false
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()
        try manager.save(loaded)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)

        XCTAssertTrue(loaded.awareness.message_preview)
        XCTAssertFalse(loaded.awareness.live_transcription)
        XCTAssertFalse(raw.contains("message_preview"))
    }

    func testLegacyCodexReasoningEffortMigratesToOrchestratorEffort() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        model = "gpt-5.5"
        codex_reasoning_effort = "high"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.model, "sol")
        XCTAssertEqual(loaded.general.orchestrator_effort, "high")
        XCTAssertEqual(loaded.general.codex_reasoning_effort, "high")
    }

    func testInvalidOrchestratorAndSubagentSettingsNormalizeToDefaults() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        orchestrator_effort = "banana"
        codex_reasoning_effort = "high"
        subagent_sizing_policy = "always"
        subagent_model = "opus"
        subagent_effort = "max"
        messenger_model = "haiku"
        messenger_effort = "ultra"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.orchestrator_effort, GeneralConfig.defaultOrchestratorEffort)
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultOrchestratorEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .orchestratorDecides)
        XCTAssertEqual(loaded.general.subagent_model, GeneralConfig.defaultSubagentModel)
        XCTAssertEqual(loaded.general.subagent_effort, GeneralConfig.defaultSubagentEffort)
        XCTAssertEqual(loaded.general.messenger_model, GeneralConfig.defaultMessengerModel)
        XCTAssertEqual(loaded.general.messenger_effort, GeneralConfig.defaultMessengerEffort)
    }

    func testLegacySubagentModelAndEffortLoadButDoNotRoundTrip() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        subagent_sizing_policy = "user_default"
        subagent_model = "strong"
        subagent_effort = "xhigh"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.subagent_sizing_policy, .userDefault)
        XCTAssertEqual(loaded.general.subagent_model, "strong")
        XCTAssertEqual(loaded.general.subagent_effort, "xhigh")

        try manager.save(loaded)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)

        XCTAssertFalse(raw.contains("subagent_model"))
        XCTAssertFalse(raw.contains("subagent_effort"))
    }

    // MARK: - STT model policy (mirrors tests/test_config.py)

    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    func testFreshInstallSTTDefaultIsOSAwareAndActive() throws {
        XCTAssertTrue(STTModelPolicy.phononDefaultActive)
        for (os, active, expected, state) in [
            (sonoma, false, "parakeet-tdt-v2", ""),
            (sequoia, false, "parakeet-tdt-v2", ""),
            (sonoma, true, "parakeet-tdt-v2", ""),
            (sequoia, true, "phonon-2", "completed"),
        ] {
            let manager = ConfigManager(
                configDir: temporaryConfigDir(),
                operatingSystem: os,
                phononDefaultActive: active
            )
            let loaded = manager.load()
            let raw = try String(contentsOf: manager.configPath, encoding: .utf8)
            XCTAssertEqual(loaded.stt.model, expected)
            XCTAssertEqual(loaded.stt.phonon_migration, state)
            XCTAssertTrue(raw.contains("model = \"\(expected)\""))
            XCTAssertNoThrow(try STTModel.resolve(loaded.stt.model, operatingSystem: os))
        }
    }

    func testExistingSTTModelsAliasesAndUnknownIDsLoadWithoutMigration() throws {
        for (raw, expected) in [
            ("parakeet-tdt-v2", "parakeet-tdt-v2"),
            ("parakeet-tdt-v3", "parakeet-tdt-v3"),
            ("phonon-2", "phonon-2"),
            ("medium.en", "parakeet-tdt-v2"),
            ("tiny.en", "parakeet-tdt-v2"),
            ("large-v3", "parakeet-tdt-v3"),
            ("whisper-xl", "whisper-xl"),
        ] {
            let manager = ConfigManager(
                configDir: temporaryConfigDir(),
                operatingSystem: sequoia,
                phononDefaultActive: true
            )
            try FileManager.default.createDirectory(
                at: manager.configPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "[stt]\nmodel = \"\(raw)\"\n".write(to: manager.configPath, atomically: true, encoding: .utf8)
            let loaded = manager.load()
            XCTAssertEqual(loaded.stt.model, expected, raw)
            XCTAssertEqual(loaded.stt.phonon_migration, "", raw)
        }
        XCTAssertThrowsError(try STTModel.resolve("whisper-xl", operatingSystem: sequoia)) { error in
            XCTAssertEqual(error as? STTModelSelectionError, .unknownModel("whisper-xl"))
        }
        XCTAssertThrowsError(try STTModel.resolve("phonon-2", operatingSystem: sonoma)) { error in
            XCTAssertEqual(
                error as? STTModelSelectionError,
                .unsupportedOperatingSystem(model: .phonon2, requiredMajorVersion: 15)
            )
        }
    }

    func testPhononMigrationFieldsRoundTrip() throws {
        let manager = ConfigManager(configDir: temporaryConfigDir())
        var config = manager.load()
        // Start from an implicit v2 user; a fresh install may already be Phonon.
        config.stt = SttConfig().applyingPhononMigration()
        try manager.save(config)

        let loaded = manager.load()
        XCTAssertEqual(loaded.stt.model, "phonon-2")
        XCTAssertEqual(loaded.stt.phonon_migration, "completed")
        XCTAssertEqual(loaded.stt.phonon_migration_previous_model, "parakeet-tdt-v2")
    }

    func testMigrationTargetsOnlyImplicitV2OnMacOS15WhenActive() {
        let implicitV2 = SttConfig()
        XCTAssertEqual(
            STTModelPolicy.migrationTarget(for: implicitV2, operatingSystem: sequoia, phononDefaultActive: true),
            .phonon2
        )
        XCTAssertNil(STTModelPolicy.migrationTarget(for: implicitV2, operatingSystem: sequoia, phononDefaultActive: false))
        XCTAssertNil(STTModelPolicy.migrationTarget(for: implicitV2, operatingSystem: sonoma, phononDefaultActive: true))
        for state in ["completed", "rolled_back", "explicit"] {
            var stt = SttConfig()
            stt.phonon_migration = state
            XCTAssertNil(STTModelPolicy.migrationTarget(for: stt, operatingSystem: sequoia, phononDefaultActive: true))
        }
        var v3 = SttConfig()
        v3.model = "parakeet-tdt-v3"
        XCTAssertNil(STTModelPolicy.migrationTarget(for: v3, operatingSystem: sequoia, phononDefaultActive: true))
    }

    func testUserModelChangesAreRecordedSoTheyAreNeverReOverridden() {
        // Explicit v3 before any migration.
        var draft = SttConfig()
        draft.model = "parakeet-tdt-v3"
        let explicit = draft.recordingUserModelChange(from: SttConfig())
        XCTAssertEqual(explicit.phonon_migration, "explicit")
        XCTAssertNil(STTModelPolicy.migrationTarget(for: explicit, operatingSystem: sequoia, phononDefaultActive: true))

        // Explicit rollback after the automatic migration.
        let migrated = SttConfig().applyingPhononMigration()
        var rollbackDraft = migrated
        rollbackDraft.model = "parakeet-tdt-v2"
        let rolledBack = rollbackDraft.recordingUserModelChange(from: migrated)
        XCTAssertEqual(rolledBack.model, "parakeet-tdt-v2")
        XCTAssertEqual(rolledBack.phonon_migration, "rolled_back")
        XCTAssertNil(STTModelPolicy.migrationTarget(for: rolledBack, operatingSystem: sequoia, phononDefaultActive: true))

        // A later OS upgrade cannot re-override a rollback either.
        XCTAssertNil(STTModelPolicy.migrationTarget(
            for: rolledBack,
            operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            phononDefaultActive: true
        ))

        // A Settings draft opened before the migration is not a rollback.
        var staleDraft = SttConfig()
        staleDraft.vad_sensitivity = "high"
        let saved = staleDraft.recordingUserModelChange(from: migrated)
        XCTAssertEqual(saved.model, "phonon-2")
        XCTAssertEqual(saved.phonon_migration, "completed")
        XCTAssertEqual(saved.vad_sensitivity, "high")

        // Edits that keep the model leave a pending user eligible.
        var vadOnly = SttConfig()
        vadOnly.vad_sensitivity = "low"
        XCTAssertEqual(vadOnly.recordingUserModelChange(from: SttConfig()).phonon_migration, "")
    }

    func testSettingsModelOptionsAreOSGated() {
        let sonomaOptions = STTSettingsTab.modelOptions(operatingSystem: sonoma, phononDefaultActive: true)
        XCTAssertEqual(sonomaOptions.map(\.value), ["parakeet-tdt-v2", "parakeet-tdt-v3"])
        XCTAssertEqual(sonomaOptions.first?.label, "Parakeet v2 (English), recommended")
        XCTAssertTrue(STTSettingsTab.modelDescription(SttConfig(), operatingSystem: sonoma)
            .contains("Phonon 2 (English) requires macOS 15 or later."))

        let sequoiaOptions = STTSettingsTab.modelOptions(operatingSystem: sequoia, phononDefaultActive: true)
        XCTAssertEqual(sequoiaOptions.map(\.value), ["phonon-2", "parakeet-tdt-v2", "parakeet-tdt-v3"])
        XCTAssertEqual(sequoiaOptions.first?.label, "Phonon 2 (English)")
        XCTAssertEqual(sequoiaOptions.last?.label, "Parakeet v3 (multilingual, larger)")

        let inactive = STTSettingsTab.modelOptions(operatingSystem: sequoia, phononDefaultActive: false)
        XCTAssertEqual(inactive[1].label, "Parakeet v2 (English), recommended")

        XCTAssertTrue(STTSettingsTab.modelDescription(SttConfig().applyingPhononMigration(), operatingSystem: sequoia)
            .contains("Choose Parakeet v2 to roll back."))
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-runner-config-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
