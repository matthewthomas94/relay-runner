from __future__ import annotations

import os
import stat
import sys
import tempfile
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

from voice_bridge import ensure_fifo, open_fifo  # noqa: E402


class VoiceBridgeFIFOTests(unittest.TestCase):
    def temp_path(self) -> str:
        temp_dir = tempfile.mkdtemp()
        self.addCleanup(lambda: os.path.isdir(temp_dir) and os.rmdir(temp_dir))
        path = os.path.join(temp_dir, "voice_in.fifo")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def assert_fifo(self, path: str) -> None:
        self.assertTrue(stat.S_ISFIFO(os.stat(path).st_mode))

    def test_ensure_fifo_replaces_regular_file(self):
        path = self.temp_path()
        with open(path, "w") as f:
            f.write("stale data")

        self.assertTrue(ensure_fifo(path))

        self.assert_fifo(path)

    def test_open_fifo_repairs_regular_file_before_opening(self):
        path = self.temp_path()
        with open(path, "w") as f:
            f.write("stale data")

        fd = open_fifo(path)
        self.addCleanup(lambda: fd is not None and os.close(fd))

        self.assertIsNotNone(fd)
        self.assert_fifo(path)


if __name__ == "__main__":
    unittest.main()
