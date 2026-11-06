"""RR-465: a same-session watchdog restart keeps the provider turn ledger."""

from __future__ import annotations

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402


class WatchdogRestartMarkerTests(unittest.TestCase):
    def _check(self, marker: str | None, *, stopping: bool, stop_requested: bool = False,
               session: str = "provider-session", pid: int = 4242) -> bool:
        with tempfile.TemporaryDirectory() as temp:
            marker_path = os.path.join(temp, "voice_bridge_watchdog_restart")
            stop_path = os.path.join(temp, "voice_bridge_stop_requested")
            if marker is not None:
                Path(marker_path).write_text(marker)
            if stop_requested:
                Path(stop_path).write_text("")
            return voice_bridge._watchdog_restart_preserves_turns(
                stopping=stopping,
                marker_path=marker_path,
                stop_path=stop_path,
                provider_session_id=session,
                pid=pid,
            )

    def test_stopping_bridge_preserves_only_when_marker_names_it(self):
        self.assertTrue(self._check("provider-session\n4242\n", stopping=True))
        self.assertFalse(self._check("provider-session\n9999\n", stopping=True), "another bridge")
        self.assertFalse(self._check("other-session\n4242\n", stopping=True), "other session")
        self.assertFalse(self._check(None, stopping=True), "no watchdog restart")

    def test_starting_bridge_preserves_for_the_same_provider_session(self):
        self.assertTrue(self._check("provider-session\n4242\n", stopping=False, pid=1))
        self.assertFalse(self._check("other-session\n4242\n", stopping=False))
        self.assertFalse(self._check("provider-session\n4242\n", stopping=False, session=""))

    def test_explicit_stop_always_cleans(self):
        for stopping in (True, False):
            self.assertFalse(self._check("provider-session\n4242\n", stopping=stopping, stop_requested=True))


if __name__ == "__main__":
    unittest.main()
