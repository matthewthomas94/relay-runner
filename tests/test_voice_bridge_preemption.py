from __future__ import annotations

import os
import queue
import sys
import tempfile
import types
import unittest
import json
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

sys.modules.setdefault(
    "numpy",
    types.SimpleNamespace(asarray=lambda samples: samples, int16=object()),
)

import voice_bridge  # noqa: E402


def claim_ready_command(path: str) -> str:
    claim = path + ".claim"
    os.rename(path, claim)
    try:
        with open(claim) as f:
            return f.read()
    finally:
        os.remove(claim)


class VoiceBridgePreemptionTests(unittest.TestCase):
    def test_newer_command_suppresses_stale_tts_after_first_claimed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            voice_bridge._write_cmd_file("first request", path=command_path)
            self.assertEqual(claim_ready_command(command_path), "first request")

            voice_bridge._write_cmd_file("second request", path=command_path)

            queued = voice_bridge._queue_tts_text(
                "stale response to first request",
                tts_queue,
                command_path=command_path,
            )

            self.assertFalse(queued)
            self.assertTrue(tts_queue.empty())
            with open(command_path) as f:
                self.assertEqual(f.read(), "second request")

    def test_latest_command_wins_before_agent_claims_input(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")

            voice_bridge._write_cmd_file("first request", path=command_path)
            voice_bridge._write_cmd_file("second request", path=command_path)

            self.assertEqual(claim_ready_command(command_path), "second request")

    def test_single_message_tts_still_queues_without_pending_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            tts_queue: queue.Queue = queue.Queue()

            queued = voice_bridge._queue_tts_text(
                "**fresh** response",
                tts_queue,
                command_path=command_path,
            )

            self.assertTrue(queued)
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_sequence_tagged_tts_drops_after_command_superseded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            tts_queue: queue.Queue = queue.Queue()

            Path(state_path).write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "second",
            }))

            stale = json.dumps({
                "text": "stale response",
                "relay_command_seq": 1,
                "relay_command_id": "first",
            })
            fresh = json.dumps({
                "text": "**fresh** response",
                "relay_command_seq": 2,
                "relay_command_id": "second",
            })

            self.assertFalse(voice_bridge._queue_tts_text(
                stale,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            self.assertTrue(voice_bridge._queue_tts_text(
                fresh,
                tts_queue,
                command_path=command_path,
                state_path=state_path,
            ))
            self.assertEqual(tts_queue.get_nowait(), "fresh response")

    def test_newer_pending_project_work_does_not_create_visible_tickets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir) / "repo"
            orch = repo / ".orchestrator"
            orch.mkdir(parents=True)
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            meta_path = os.path.join(temp_dir, "voice_cmd_ready.meta")
            state_path = os.path.join(temp_dir, "voice_command_state.json")
            event_path = os.path.join(temp_dir, "voice_command_events.jsonl")

            first_meta = voice_bridge._begin_relay_command(
                "fix the login bug",
                state_path,
                event_log_path=event_path,
            )
            first_action = voice_bridge.resolve_command_action(
                "fix the login bug",
                repo_path=repo,
                relay_command=first_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(first_action),
                voice_bridge._metadata_for_action(first_action, first_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            self.assertFalse((orch / "RR-3.md").exists())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 3\n')

            second_meta = voice_bridge._begin_relay_command(
                "fix the signup bug",
                state_path,
                event_log_path=event_path,
            )
            second_action = voice_bridge.resolve_command_action(
                "fix the signup bug",
                repo_path=repo,
                relay_command=second_meta,
            )
            voice_bridge._publish_command(
                voice_bridge.format_command_for_agent(second_action),
                voice_bridge._metadata_for_action(second_action, second_meta),
                command_path=command_path,
                meta_path=meta_path,
                state_path=state_path,
            )

            self.assertFalse((orch / "RR-3.md").exists())
            self.assertFalse((orch / "RR-4.md").exists())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 3\n')
            with open(command_path) as f:
                command = f.read()
            self.assertIn("ticket_id: null", command)
            self.assertIn("No visible ticket has been written yet", command)
            meta = json.loads(Path(meta_path).read_text())
            self.assertNotIn("ticket_id", meta)
            self.assertEqual(meta["action"], "create_ticket")
            self.assertEqual(meta["relay_command_seq"], 2)
            events = [json.loads(line) for line in Path(event_path).read_text().splitlines()]
            self.assertEqual([event["source_text"] for event in events], [
                "fix the login bug",
                "fix the signup bug",
            ])

    def test_private_command_event_log_is_bounded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            event_path = os.path.join(temp_dir, "voice_command_events.jsonl")

            for idx in range(4):
                voice_bridge._record_private_command_capture(
                    {
                        "relay_command_seq": idx + 1,
                        "relay_command_id": f"cmd-{idx + 1}",
                        "received_at": float(idx),
                        "source_text": f"command {idx + 1}",
                        "action": "received",
                    },
                    event_log_path=event_path,
                    limit=2,
                )

            events = [json.loads(line) for line in Path(event_path).read_text().splitlines()]
            self.assertEqual([event["relay_command_seq"] for event in events], [3, 4])

    def test_generated_provider_skills_share_preemption_contract(self):
        script_path = os.path.join(ROOT, "scripts", "relay-bridge")
        with open(script_path) as f:
            script = f.read()

        self.assertEqual(
            script.count("Codex and Claude use the same cooperative preemption contract"),
            2,
        )
        self.assertEqual(
            script.count("Run the preemption checkpoint immediately before"),
            2,
        )
        self.assertEqual(
            script.count("Codex and Claude follow the same command-action contract"),
            2,
        )
        self.assertGreaterEqual(
            script.count("cmd_tmp=$(mktemp /tmp/voice_cmd_claim.XXXXXX) || exit 1"),
            4,
        )
        self.assertGreaterEqual(
            script.count("voice_cmd_claimed.json"),
            8,
        )
        self.assertGreaterEqual(
            script.count("voice_bridge_stop_requested"),
            10,
        )
        self.assertEqual(
            script.count("if [ -f /tmp/voice_bridge_stop_requested ]; then"),
            4,
        )


if __name__ == "__main__":
    unittest.main()
