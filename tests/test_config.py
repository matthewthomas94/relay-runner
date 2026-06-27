from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from config import load_config  # noqa: E402


class ConfigTests(unittest.TestCase):
    def test_codex_gpt56_preview_models_are_preserved(self):
        for model in ("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"):
            with self.subTest(model=model), tempfile.TemporaryDirectory() as tmp:
                config_path = Path(tmp) / "config.toml"
                config_path.write_text(
                    f'[general]\nprovider = "codex"\nmodel = "{model}"\n',
                    encoding="utf-8",
                )

                config = load_config(str(config_path))

                self.assertEqual(config["general"]["provider"], "codex")
                self.assertEqual(config["general"]["model"], model)

    def test_codex_gpt56_preview_model_resets_for_claude(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.toml"
            config_path.write_text(
                '[general]\nprovider = "claude"\nmodel = "gpt-5.6-sol"\n',
                encoding="utf-8",
            )

            config = load_config(str(config_path))

            self.assertEqual(config["general"]["provider"], "claude")
            self.assertEqual(config["general"]["model"], "default")

    def test_load_config_defaults_codex_reasoning_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")

            config = load_config(path)

        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")
        self.assertEqual(config["general"]["orchestrator_effort"], "default")
        self.assertEqual(config["general"]["subagent_sizing_policy"], "orchestrator_decides")
        self.assertEqual(config["general"]["subagent_model"], "balanced")
        self.assertEqual(config["general"]["subagent_effort"], "medium")

    def test_load_config_normalizes_codex_reasoning_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "claude"
                    command = "claude"
                    codex_reasoning_effort = " XHIGH "
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["provider"], "claude")
        self.assertEqual(config["general"]["orchestrator_effort"], "xhigh")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "xhigh")

    def test_load_config_allows_claude_orchestrator_effort_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "claude"
                    command = "claude"
                    orchestrator_effort = "max"
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["orchestrator_effort"], "max")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")

    def test_load_config_rejects_codex_orchestrator_effort_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "codex"
                    command = "codex"
                    orchestrator_effort = "max"
                    codex_reasoning_effort = "high"
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["orchestrator_effort"], "default")
        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")

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


if __name__ == "__main__":
    unittest.main()
