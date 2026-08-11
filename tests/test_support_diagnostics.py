from __future__ import annotations

import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from services import support_diagnostics


class SupportDiagnosticsTests(unittest.TestCase):
    def test_schema_is_allowlisted_redacted_and_provider_neutral(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict(
            os.environ, {"RELAY_DIAGNOSTICS_DIR": temp}
        ):
            events = [
                support_diagnostics.record_event(
                    process="provider",
                    phase="provider_readiness",
                    outcome="failed",
                    provider=provider,
                    summary="/Users/alice/repo /opt/homebrew/bin token=secret-value",
                    attributes={"error_code": "Bearer abcdefghijk"},
                )
                for provider in ("codex", "claude")
            ]

            self.assertEqual(set(events[0]), set(events[1]))
            self.assertNotIn("/Users/alice", events[0]["summary"])
            self.assertNotIn("/opt/homebrew", events[0]["summary"])
            self.assertNotIn("secret-value", events[0]["summary"])
            self.assertGreaterEqual(events[0]["redaction_count"], 3)
            self.assertIsNone(support_diagnostics.record_event(
                process="provider",
                phase="provider_readiness",
                outcome="failed",
                provider="unknown",
            ))
            self.assertIsNone(support_diagnostics.record_event(
                process="app",
                phase="workspace_readiness",
                outcome="failed",
                attributes={"repository_path": "/Users/alice/repo"},
            ))

            paths = list(Path(temp).glob("events-v1-provider-*.jsonl"))
            self.assertEqual(len(paths), 1)
            self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)
            rows = [json.loads(line) for line in paths[0].read_text().splitlines()]
            self.assertEqual([row["provider"] for row in rows], ["codex", "claude"])

    def test_retention_prunes_expired_journals(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict(
            os.environ, {"RELAY_DIAGNOSTICS_DIR": temp}
        ):
            expired = Path(temp) / "events-v1-shell-expired.jsonl"
            expired.write_text("{}\n")
            old = time.time() - (support_diagnostics.RETENTION_DAYS + 1) * 86400
            os.utime(expired, (old, old))

            support_diagnostics.record_event(
                process="orchestrator",
                phase="orchestrator_launch",
                outcome="ready",
            )

            self.assertFalse(expired.exists())

    def test_orchestrator_lifecycle_reuses_exported_correlation(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict(
            os.environ,
            {
                "RELAY_DIAGNOSTICS_DIR": temp,
                "RELAY_CORRELATION_ID": "orchestrator-lifecycle-test",
            },
        ):
            events = [
                support_diagnostics.record_event(
                    process="orchestrator",
                    phase="orchestrator_launch",
                    outcome=outcome,
                )
                for outcome in ("started", "ready", "failed")
            ]

            self.assertEqual(
                {event["correlation_id"] for event in events},
                {"orchestrator-lifecycle-test"},
            )

    def test_release_build_retains_matching_private_symbols_contract(self):
        root = Path(__file__).resolve().parent.parent
        script = (root / "scripts/build-dmg.sh").read_text()
        workflow = (root / ".github/workflows/build-dmg.yml").read_text()
        self.assertIn("-Xswiftc -g", script)
        self.assertIn("xcrun dsymutil", script)
        self.assertIn("xcrun dwarfdump --uuid", script)
        self.assertIn("dist/RelayRunner-dSYMs.zip", workflow)
        public_release = workflow.split("- name: Upload release artifacts", 1)[1].split(
            "- name: Upload public Sparkle update artifacts", 1
        )[0]
        self.assertNotIn("RelayRunner-dSYMs", public_release)


if __name__ == "__main__":
    unittest.main()
