"""RR-403: the bridge records its own PID so it is stopped by PID, never by pattern."""

from __future__ import annotations

import os
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "services"))
sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))

import voice_bridge  # noqa: E402


class BridgePidFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="rr403-")
        self.addCleanup(self.temp.cleanup)
        self.path = os.path.join(self.temp.name, "voice_bridge.pid")
        patcher = mock.patch.object(voice_bridge, "BRIDGE_PID_FILE", self.path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_pid_file_holds_this_process_and_is_removed_on_exit(self):
        voice_bridge._write_bridge_pid_file()
        with open(self.path) as f:
            self.assertEqual(f.read().strip(), str(os.getpid()))
        voice_bridge._remove_bridge_pid_file()
        self.assertFalse(os.path.exists(self.path))

    def test_exit_does_not_remove_a_successors_pid_file(self):
        with open(self.path, "w") as f:
            f.write(f"{os.getpid() + 1}\n")
        voice_bridge._remove_bridge_pid_file()
        self.assertTrue(os.path.exists(self.path))

    def test_no_pattern_kill_of_the_bridge_remains(self):
        for relative in ("scripts/relay-bridge", "services/voice_bridge.py"):
            with open(os.path.join(ROOT, relative)) as f:
                self.assertNotIn("pkill", f.read(), relative)


if __name__ == "__main__":
    unittest.main()
