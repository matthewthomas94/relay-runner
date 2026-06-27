from __future__ import annotations

import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from config import load_config  # noqa: E402


class ConfigTests(unittest.TestCase):
    def test_load_config_defaults_codex_reasoning_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")

            config = load_config(path)

        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")

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
        self.assertEqual(config["general"]["codex_reasoning_effort"], "xhigh")

    def test_load_config_rejects_codex_reasoning_effort_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(
                    """
                    [general]
                    provider = "codex"
                    command = "codex"
                    codex_reasoning_effort = "max"
                    """
                )

            config = load_config(path)

        self.assertEqual(config["general"]["codex_reasoning_effort"], "default")


if __name__ == "__main__":
    unittest.main()
