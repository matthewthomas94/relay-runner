from __future__ import annotations

import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from intent_inbox import IntentInbox, sync_deliverable_state  # noqa: E402


def metadata(seq: int, command_id: str, route: str = "continue_current") -> dict:
    return {
        "relay_command_seq": seq,
        "relay_command_id": command_id,
        "intent_id": f"intent-{seq}",
        "work_disposition": {"route": route},
    }


class IntentInboxTests(unittest.TestCase):
    def test_existing_v1_database_adds_stable_ack_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            connection = sqlite3.connect(path)
            connection.executescript(
                """
                CREATE TABLE intents (
                    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                    intent_id TEXT NOT NULL UNIQUE,
                    command_seq INTEGER NOT NULL,
                    command_id TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    route TEXT NOT NULL,
                    state TEXT NOT NULL,
                    delivery_id TEXT NOT NULL UNIQUE,
                    claim_id TEXT,
                    created_at REAL NOT NULL,
                    delivered_at REAL,
                    claimed_at REAL,
                    acked_at REAL,
                    cancelled_at REAL,
                    transport TEXT
                );
                """
            )
            connection.close()

            inbox = IntentInbox(path)
            inbox.enqueue("first", metadata(1, "one"), "continue_current")
            inbox.observe_claim(metadata(1, "one"), provider_turn_seen=True)

            self.assertEqual(inbox.records()[0]["ack_id"], "ack:intent-1")

    def test_fifo_preserves_multiple_pending_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            command = str(Path(directory) / "ready")
            meta = command + ".meta"
            inbox.enqueue("first", metadata(1, "one"), "continue_current")
            inbox.enqueue("second", metadata(2, "two"), "queue_project_work")

            first = inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )
            self.assertEqual(Path(command).read_text(), "first")
            self.assertEqual(first["relay_command_id"], "one")
            os.unlink(command)
            os.unlink(meta)

            second = inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="manual-bridge",
            )
            self.assertEqual(Path(command).read_text(), "second")
            self.assertEqual(second["relay_command_id"], "two")
            self.assertEqual(
                [record["state"] for record in inbox.records()],
                ["delivered", "delivered"],
            )
            self.assertEqual(
                [record["transport"] for record in inbox.records()],
                ["app-owned", "manual-bridge"],
            )

    def test_claim_and_ack_identity_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            inbox.enqueue("first", metadata(1, "one"), "continue_current")
            self.assertTrue(inbox.observe_claim(metadata(1, "one"), provider_turn_seen=False))
            self.assertTrue(inbox.observe_claim(metadata(1, "one"), provider_turn_seen=True))
            record = inbox.records()[0]
            self.assertEqual(record["state"], "acked")
            self.assertEqual(record["claim_id"], "claim:intent-1")
            self.assertEqual(record["ack_id"], "ack:intent-1")
            self.assertIsNotNone(record["acked_at"])

    def test_explicit_replace_cancels_only_unaccepted_older_intents(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            inbox.enqueue("first", metadata(1, "one"), "queue_project_work")
            inbox.enqueue("second", metadata(2, "two"), "continue_current")
            inbox.observe_claim(metadata(1, "one"), provider_turn_seen=True)

            cancelled = inbox.cancel_pending_before(3, reason="explicit_replace")

            self.assertEqual(cancelled, 1)
            self.assertEqual(
                [record["state"] for record in inbox.records()],
                ["acked", "cancelled"],
            )

    def test_state_lists_deliverable_commands_without_overloading_latest_key(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            state = Path(directory) / "state.json"
            state.write_text(json.dumps({
                "relay_command_seq": 2,
                "relay_command_id": "two",
            }))
            inbox.enqueue("first", metadata(1, "one"), "continue_current")
            inbox.enqueue("second", metadata(2, "two"), "continue_current")

            sync_deliverable_state(str(state), inbox)

            payload = json.loads(state.read_text())
            self.assertEqual(payload["relay_command_id"], "two")
            self.assertEqual(
                [item["relay_command_id"] for item in payload["deliverable_commands"]],
                ["one", "two"],
            )


if __name__ == "__main__":
    unittest.main()
