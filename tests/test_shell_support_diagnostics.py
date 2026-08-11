from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MAXIMUM_BYTES = 5 * 1024 * 1024


def shell_function(source: str, name: str) -> str:
    start = source.index(f"{name}() {{")
    end = source.index("\n}\n", start) + 3
    return source[start:end]


class ShellSupportDiagnosticsTests(unittest.TestCase):
    def test_each_shell_writer_enforces_age_and_aggregate_size_bounds(self):
        function_names = (
            "support_file_mtime",
            "support_file_size",
            "prune_support_journals",
            "record_support_event",
        )
        for relative_path in ("scripts/relay-bridge", "scripts/relay-orchestrator"):
            with self.subTest(writer=relative_path), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                expired = directory / "events-v1-shell-expired.jsonl"
                oldest = directory / "events-v1-shell-oldest.jsonl"
                newest = directory / "events-v1-shell-newest.jsonl"
                expired.write_text("{}\n")
                oldest.write_bytes(b"a" * (3 * 1024 * 1024))
                newest.write_bytes(b"b" * (3 * 1024 * 1024))
                now = time.time()
                os.utime(expired, (now - 8 * 86400, now - 8 * 86400))
                os.utime(oldest, (now - 120, now - 120))
                os.utime(newest, (now - 60, now - 60))

                source = (ROOT / relative_path).read_text()
                harness = "\n".join(shell_function(source, name) for name in function_names)
                harness += "\nrecord_support_event shell setup started\n"
                result = subprocess.run(
                    ["/bin/bash", "-c", harness],
                    env={
                        **os.environ,
                        "RELAY_DIAGNOSTICS_DIR": str(directory),
                        "RELAY_CORRELATION_ID": "correlation-test",
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(expired.exists())
                self.assertFalse(oldest.exists())
                self.assertTrue(newest.exists())
                total = sum(path.stat().st_size for path in directory.glob("events-v1-*.jsonl"))
                self.assertLessEqual(total, MAXIMUM_BYTES)


if __name__ == "__main__":
    unittest.main()
