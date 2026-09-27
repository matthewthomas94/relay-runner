from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "services"
sys.path.insert(0, str(SERVICES))

import relay_completion_hook  # noqa: E402


class SessionStartHookTests(unittest.TestCase):
    """Claude's SessionStart runs after its first-run screens; the embedded
    terminal waits for the stage this records before typing voice input."""

    def test_session_start_records_the_first_run_boundary_only(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            events = root / "session.events.jsonl"

            def refuse(_event):
                raise AssertionError("SessionStart must not publish bridge events")

            handled = relay_completion_hook.handle_hook_payload(
                {"hook_event_name": "SessionStart", "source": "startup", "session_id": "s-1"},
                claim_path=str(root / "claimed.json"),
                state_path=str(root / "state.json"),
                turns_path=str(root / "turns.json"),
                manual_submissions_path=str(root / "manual.json"),
                write_control=refuse,
                write_provider_event=refuse,
                session_events_path=str(events),
                now=1_800_000_000,
            )

            self.assertFalse(handled)
            records = [json.loads(line) for line in events.read_text().splitlines()]
            self.assertEqual(
                records,
                [{"outcome": "ready", "stage": "provider_session_start", "timestamp": "2027-01-15T08:00:00Z"}],
            )
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["session.events.jsonl"])

    def test_hook_prints_nothing_claude_would_add_to_context(self):
        # Claude runs the hook with /usr/bin/python3 and adds SessionStart
        # stdout to the conversation.
        with tempfile.TemporaryDirectory() as temp:
            events = Path(temp) / "session.events.jsonl"
            env = {
                **os.environ,
                "RELAY_SESSION_EVENTS": str(events),
                "VOICE_COMMAND_STATE_FILE": str(Path(temp) / "state.json"),
                "VOICE_COMMAND_CLAIM_FILE": str(Path(temp) / "claimed.json"),
                "VOICE_PROVIDER_TURNS_FILE": str(Path(temp) / "turns.json"),
            }
            result = subprocess.run(
                ["/usr/bin/python3", str(SERVICES / "relay_completion_hook.py")],
                input=json.dumps({"hook_event_name": "SessionStart", "source": "startup"}),
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertIn('"stage":"provider_session_start"', events.read_text())


if __name__ == "__main__":
    unittest.main()
