from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services"))

from orchestrator import _find_agent_bin  # noqa: E402


CHATGPT_CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
LEGACY_CODEX = "/Applications/Codex.app/Contents/Resources/codex"


class OrchestratorAgentBinaryTests(unittest.TestCase):
    def test_chatgpt_codex_precedes_legacy_app_and_path(self):
        with patch("orchestrator.shutil.which", return_value="/usr/local/bin/codex") as which, \
                patch("orchestrator.os.access", return_value=True) as access:
            self.assertEqual(_find_agent_bin("codex"), CHATGPT_CODEX)
            access.assert_called_once_with(CHATGPT_CODEX, os.X_OK)
            which.assert_not_called()

    def test_legacy_codex_remains_a_fallback(self):
        with patch("orchestrator.shutil.which", return_value=None), \
                patch(
                    "orchestrator.os.access",
                    side_effect=lambda candidate, _: candidate == LEGACY_CODEX,
                ):
            self.assertEqual(_find_agent_bin("codex"), LEGACY_CODEX)

    def test_path_codex_remains_a_fallback(self):
        with patch("orchestrator.shutil.which", return_value="/usr/local/bin/codex"), \
                patch("orchestrator.os.access", return_value=False):
            self.assertEqual(_find_agent_bin("codex"), "/usr/local/bin/codex")

    def test_missing_codex_names_both_supported_app_locations(self):
        with patch("orchestrator.shutil.which", return_value=None), \
                patch("orchestrator.os.access", return_value=False), \
                self.assertRaisesRegex(RuntimeError, "ChatGPT/Codex applications"):
            _find_agent_bin("codex")


if __name__ == "__main__":
    unittest.main()
