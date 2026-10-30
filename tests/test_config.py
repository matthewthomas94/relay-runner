from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from config import (  # noqa: E402
    PHONON_DEFAULT_ACTIVE,
    default_stt_model,
    load_config,
    stt_migration_target,
    stt_model_supported,
)


class ConfigTests(unittest.TestCase):
    def test_codex_suffixed_models_migrate_to_families(self):
        for model, family in (
            ("gpt-5.6-sol", "sol"),
            ("gpt-5.6-terra", "sol"),
            ("gpt-5.6-luna", "luna"),
        ):
            with self.subTest(model=model), tempfile.TemporaryDirectory() as tmp:
                config_path = Path(tmp) / "config.toml"
                config_path.write_text(
                    f'[general]\nprovider = "codex"\nmodel = "{model}"\n',
                    encoding="utf-8",
                )

                config = load_config(str(config_path))

                self.assertEqual(config["general"]["provider"], "codex")
                self.assertEqual(config["general"]["model"], family)

    def test_codex_gpt56_preview_model_resets_for_claude(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text(
                '[general]\nprovider = "claude"\nmodel = "gpt-5.6-sol"\n',
                encoding="utf-8",
            )

            config = load_config(str(config_path))

            self.assertEqual(config["general"]["provider"], "claude")
            self.assertEqual(config["general"]["model"], "opus")

    def test_load_config_defaults_codex_reasoning_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")

            config = load_config(path)

        self.assertEqual(config["tts"]["voice"], "am_puck")
        self.assertEqual(config["tts"]["rate"], 1.3)
        self.assertEqual(config["general"]["codex_reasoning_effort"], "medium")
        self.assertEqual(config["general"]["orchestrator_effort"], "medium")
        self.assertEqual(config["general"]["subagent_sizing_policy"], "orchestrator_decides")
        self.assertNotIn("subagent_model", config["general"])
        self.assertNotIn("subagent_effort", config["general"])
        self.assertTrue(config["general"]["messenger_enabled"])
        self.assertEqual(config["general"]["messenger_model"], "luna")
        self.assertEqual(config["general"]["messenger_effort"], "low")
        self.assertFalse(config["general"]["prevent_sleep_while_running"])
        self.assertEqual(config["orchestrator"]["worker_health_check_seconds"], 600)
        self.assertNotIn("worker_timeout_seconds", config["orchestrator"])

    def test_load_config_defaults_claude_orchestrator_to_explicit_opus_and_medium(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text('[general]\nprovider = "claude"\n', encoding="utf-8")

            config = load_config(str(path))

        self.assertEqual(config["general"]["model"], "opus")
        self.assertEqual(config["general"]["orchestrator_effort"], "medium")
        self.assertEqual(config["general"]["messenger_model"], "haiku")
        self.assertEqual(config["general"]["messenger_effort"], "default")

    def test_worker_agent_follows_general_provider_and_drops_other_provider_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                '[general]\nprovider = "claude"\n'
                'command = "/Applications/ChatGPT.app/Contents/Resources/codex"\n',
                encoding="utf-8",
            )

            config = load_config(str(path))

        # No implicit [orchestrator].agent override: workers follow general.provider.
        self.assertEqual(config["orchestrator"]["agent"], "")
        self.assertEqual(config["general"]["command"], "claude")

    def test_custom_absolute_command_for_selected_provider_is_kept(self):
        for provider, command in (
            ("codex", "/Applications/ChatGPT.app/Contents/Resources/codex"),
            ("claude", "/opt/homebrew/bin/claude"),
        ):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "config.toml"
                path.write_text(
                    f'[general]\nprovider = "{provider}"\ncommand = "{command}"\n',
                    encoding="utf-8",
                )
                config = load_config(str(path))
            self.assertEqual(config["general"]["command"], command)

    def test_load_config_migrates_legacy_orchestrator_values_without_resetting_explicit_values(self):
        cases = [
            ("claude", "best", "default", "opus", "medium"),
            ("codex", "sol", "high", "sol", "high"),
        ]
        for provider, model, effort, expected_model, expected_effort in cases:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "config.toml"
                path.write_text(
                    f'[general]\nprovider = "{provider}"\nmodel = "{model}"\n'
                    f'orchestrator_effort = "{effort}"\n',
                    encoding="utf-8",
                )
                config = load_config(str(path))

            self.assertEqual(config["general"]["model"], expected_model)
            self.assertEqual(config["general"]["orchestrator_effort"], expected_effort)

    def test_load_config_preserves_prevent_sleep_while_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [general]
                prevent_sleep_while_running = true
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertTrue(config["general"]["prevent_sleep_while_running"])

    def test_load_config_defaults_missing_tts_rate_to_one_point_three(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [tts]
                voice = "bf_isabella"
                auto_play = true
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertEqual(config["tts"]["voice"], "bf_isabella")
        self.assertTrue(config["tts"]["auto_play"])
        self.assertEqual(config["tts"]["rate"], 1.3)

    def test_load_config_falls_back_to_puck_for_voice_outside_standard_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [tts]
                voice = "af_bella"
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertEqual(config["tts"]["voice"], "am_puck")

    def test_load_config_preserves_explicit_tts_rate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [tts]
                rate = 1.1
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertEqual(config["tts"]["rate"], 1.1)

    def test_load_config_normalizes_codex_reasoning_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "codex"
                    command = "codex"
                    model = "gpt-5.5"
                    codex_reasoning_effort = " XHIGH "
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["provider"], "codex")
        self.assertEqual(config["general"]["orchestrator_effort"], "xhigh")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "xhigh")

    def test_load_config_allows_model_specific_claude_orchestrator_effort_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "claude"
                    command = "claude"
                    model = "fable"
                    orchestrator_effort = "max"
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["model"], "fable")
        self.assertEqual(config["general"]["orchestrator_effort"], "max")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")

    def test_load_config_rejects_unknown_codex_orchestrator_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "codex"
                    command = "codex"
                    orchestrator_effort = "banana"
                    codex_reasoning_effort = "high"
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["orchestrator_effort"], "medium")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "medium")

    def test_load_config_applies_rr150_model_effort_matrix(self):
        cases = [
            ("codex", "sol", "ultra", "sol", "ultra"),
            ("codex", "terra", "ultra", "sol", "ultra"),
            ("codex", "luna", "max", "luna", "max"),
            ("codex", "luna", "ultra", "luna", "ultra"),
            ("codex", "gpt-5.5", "xhigh", "sol", "xhigh"),
            ("codex", "gpt-5.6-terra", "max", "sol", "max"),
            ("codex", "gpt-5.3-codex-spark", "xhigh", "sol", "xhigh"),
            ("codex", "default", "low", "sol", "low"),
            ("claude", "best", "max", "opus", "max"),
            ("claude", "fable", "xhigh", "fable", "xhigh"),
            ("claude", "opus", "max", "opus", "max"),
            ("claude", "sonnet", "max", "sonnet", "max"),
            ("claude", "sonnet", "xhigh", "sonnet", "xhigh"),
            ("claude", "haiku", "low", "haiku", "low"),
            ("claude", "default", "low", "opus", "low"),
        ]

        for provider, model, effort, expected_model, expected_effort in cases:
            with self.subTest(provider=provider, model=model, effort=effort), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "config.toml"
                path.write_text(
                    "\n".join(
                        [
                            "[general]",
                            f'provider = "{provider}"',
                            f'command = "{provider}"',
                            f'model = "{model}"',
                            f'orchestrator_effort = "{effort}"',
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )

                config = load_config(str(path))

                self.assertEqual(config["general"]["model"], expected_model)
                self.assertEqual(config["general"]["orchestrator_effort"], expected_effort)

    def test_load_config_normalizes_subagent_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    subagent_sizing_policy = "user_default"
                    subagent_model = " STRONG "
                    subagent_effort = " XHIGH "
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["subagent_sizing_policy"], "user_default")
        self.assertEqual(config["general"]["subagent_model"], "strong")
        self.assertEqual(config["general"]["subagent_effort"], "xhigh")

    def test_load_config_preserves_provider_valid_messenger_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [general]
                provider = "claude"
                command = "claude"
                messenger_enabled = false
                messenger_model = "sonnet"
                messenger_effort = "low"
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertFalse(config["general"]["messenger_enabled"])
        self.assertEqual(config["general"]["messenger_model"], "sonnet")
        self.assertEqual(config["general"]["messenger_effort"], "low")

    def test_load_config_resets_cross_provider_messenger_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text(
                """
                [general]
                provider = "codex"
                command = "codex"
                messenger_model = "haiku"
                messenger_effort = "ultra"
                """,
                encoding="utf-8",
            )

            config = load_config(str(path))

        self.assertEqual(config["general"]["messenger_model"], "luna")
        self.assertEqual(config["general"]["messenger_effort"], "low")

    def test_load_config_migrates_generated_foreground_messenger_defaults(self):
        cases = (
            ("codex", "sol", "default", "luna", "low"),
            ("claude", "best", "default", "haiku", "default"),
        )
        for provider, model, effort, expected_model, expected_effort in cases:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "config.toml"
                path.write_text(
                    "[general]\n"
                    f'provider = "{provider}"\n'
                    f'messenger_model = "{model}"\n'
                    f'messenger_effort = "{effort}"\n',
                    encoding="utf-8",
                )

                config = load_config(str(path))

            self.assertEqual(config["general"]["messenger_model"], expected_model)
            self.assertEqual(config["general"]["messenger_effort"], expected_effort)

    def _load_stt(self, text: str | None, **kwargs) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            if text is not None:
                config_path.write_text(text, encoding="utf-8")
            return load_config(str(config_path), **kwargs)["stt"]

    def test_fresh_stt_default_is_os_aware_and_active(self):
        self.assertTrue(PHONON_DEFAULT_ACTIVE)
        self.assertEqual(self._load_stt(None, macos_major=14)["model"], "parakeet-tdt-v2")
        self.assertEqual(self._load_stt(None, macos_major=15)["model"], "phonon-2")
        inactive_15 = self._load_stt(None, macos_major=15, phonon_default_active=False)
        self.assertEqual(inactive_15["model"], "parakeet-tdt-v2")
        fresh_14 = self._load_stt(None, macos_major=14, phonon_default_active=True)
        self.assertEqual(fresh_14["model"], "parakeet-tdt-v2")
        self.assertEqual(fresh_14["phonon_migration"], "")
        fresh_15 = self._load_stt(None, macos_major=15, phonon_default_active=True)
        self.assertEqual(fresh_15["model"], "phonon-2")
        self.assertEqual(fresh_15["phonon_migration"], "completed")

    def test_existing_stt_models_aliases_and_unknown_ids_load_verbatim(self):
        for raw, expected in (
            ("parakeet-tdt-v2", "parakeet-tdt-v2"),
            ("parakeet-tdt-v3", "parakeet-tdt-v3"),
            ("phonon-2", "phonon-2"),
            ("medium.en", "parakeet-tdt-v2"),
            ("tiny.en", "parakeet-tdt-v2"),
            ("large-v3", "parakeet-tdt-v3"),
            ("whisper-xl", "whisper-xl"),
        ):
            with self.subTest(raw=raw):
                stt = self._load_stt(
                    f'[stt]\nmodel = "{raw}"\n', macos_major=15, phonon_default_active=True
                )
                self.assertEqual(stt["model"], expected)
                self.assertEqual(stt["phonon_migration"], "")
        # An existing file without a model key keeps the legacy v2 default.
        stt = self._load_stt('[stt]\nvad_sensitivity = "low"\n', macos_major=15, phonon_default_active=True)
        self.assertEqual(stt["model"], "parakeet-tdt-v2")

    def test_stt_os_support_matches_swift(self):
        self.assertFalse(stt_model_supported("phonon-2", 14))
        self.assertTrue(stt_model_supported("phonon-2", 15))
        self.assertTrue(stt_model_supported("parakeet-tdt-v2", 14))
        self.assertTrue(stt_model_supported("parakeet-tdt-v3", 14))
        self.assertFalse(stt_model_supported("whisper-xl", 26))
        self.assertEqual(default_stt_model(14, True), "parakeet-tdt-v2")
        self.assertEqual(default_stt_model(15, True), "phonon-2")
        self.assertEqual(default_stt_model(26, False), "parakeet-tdt-v2")

    def test_stt_migration_targets_only_implicit_v2_on_macos15(self):
        implicit_v2 = {"model": "parakeet-tdt-v2", "phonon_migration": ""}
        self.assertEqual(stt_migration_target(implicit_v2, 15, True), "phonon-2")
        self.assertIsNone(stt_migration_target(implicit_v2, 15, False))
        self.assertIsNone(stt_migration_target(implicit_v2, 14, True))
        for state in ("completed", "rolled_back", "explicit"):
            with self.subTest(state=state):
                stt = {"model": "parakeet-tdt-v2", "phonon_migration": state}
                self.assertIsNone(stt_migration_target(stt, 15, True))
        self.assertIsNone(
            stt_migration_target({"model": "parakeet-tdt-v3", "phonon_migration": ""}, 15, True)
        )

    def test_stt_migration_fields_round_trip(self):
        stt = self._load_stt(
            '[stt]\nmodel = "parakeet-tdt-v2"\nphonon_migration = "rolled_back"\n'
            'phonon_migration_previous_model = "parakeet-tdt-v2"\n',
            macos_major=26,
            phonon_default_active=True,
        )
        self.assertEqual(stt["phonon_migration"], "rolled_back")
        self.assertEqual(stt["phonon_migration_previous_model"], "parakeet-tdt-v2")
        self.assertIsNone(stt_migration_target(stt, 26, True))


if __name__ == "__main__":
    unittest.main()
