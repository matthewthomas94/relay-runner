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


def item_metadata(
    seq: int,
    command_id: str,
    order: int,
    *,
    target: str,
    route: str = "queue_project_work",
) -> dict:
    intent_id = f"{command_id}:item:{order}"
    return {
        "relay_command_seq": seq,
        "relay_command_id": command_id,
        "intent_id": intent_id,
        "within_turn_order": order,
        "target": target,
        "voice_work_item": {
            "intent_id": intent_id,
            "source_command_seq": seq,
            "source_command_id": command_id,
            "within_turn_order": order,
            "source_text": f"fix {target}",
            "target": target,
            "disposition": "accepted",
            "cancellation_scope": "none",
            "lifecycle_state": "recognized",
            "target_intent_ids": [],
        },
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

            self.assertIsNone(inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="manual-bridge",
            ))
            inbox.observe_claim(first, provider_turn_seen=True)
            second = inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="manual-bridge",
            )
            self.assertEqual(Path(command).read_text(), "second")
            self.assertEqual(second["relay_command_id"], "two")
            self.assertEqual(
                [record["state"] for record in inbox.records()],
                ["acked", "delivered"],
            )
            self.assertEqual(
                [record["transport"] for record in inbox.records()],
                ["app-owned", "manual-bridge"],
            )

    def test_restart_releases_oldest_unacked_delivery_before_later_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            command = str(Path(directory) / "ready")
            meta = command + ".meta"
            inbox = IntentInbox(path)
            first_metadata = inbox.enqueue("first", metadata(1, "one"), "continue_current")
            inbox.enqueue("second", metadata(2, "two"), "continue_current")
            inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )
            os.unlink(command)
            os.unlink(meta)
            inbox.close()

            restarted = IntentInbox(path)
            recovered = restarted.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )

            self.assertEqual(recovered["intent_delivery_id"], first_metadata["intent_delivery_id"])
            self.assertEqual(Path(command).read_text(), "first")
            self.assertEqual(
                [record["state"] for record in restarted.records()],
                ["delivered", "pending"],
            )
            self.assertEqual(restarted.records()[0]["lease_attempts"], 2)
            self.assertIsNotNone(restarted.records()[0]["recovered_at"])

            os.unlink(command)
            os.unlink(meta)
            self.assertIsNone(restarted.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            ))
            restarted.observe_claim(recovered, provider_turn_seen=True)
            advanced = restarted.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )
            self.assertEqual(advanced["relay_command_id"], "two")

    def test_restart_holds_claim_without_provider_ack_for_review(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            command = str(Path(directory) / "ready")
            meta = command + ".meta"
            inbox = IntentInbox(path)
            first = inbox.enqueue("first", metadata(1, "one"), "continue_current")
            inbox.enqueue("second", metadata(2, "two"), "continue_current")
            inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="manual-bridge",
            )
            inbox.observe_claim(first, provider_turn_seen=False)
            os.unlink(command)
            os.unlink(meta)
            inbox.close()

            restarted = IntentInbox(path)
            recovered = restarted.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="manual-bridge",
            )

            self.assertIsNone(recovered)
            self.assertEqual(
                [record["state"] for record in restarted.records()],
                ["review_required", "pending"],
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

    def test_explicit_replace_cancels_unacked_claim_but_preserves_sidecar(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            foreground = inbox.enqueue("first", metadata(1, "one"), "continue_current")
            sidecar = inbox.enqueue(
                "research",
                metadata(2, "two", "run_sidecar"),
                "run_sidecar",
            )
            inbox.observe_claim(foreground, provider_turn_seen=False)
            inbox.observe_claim(sidecar, provider_turn_seen=False)

            cancelled = inbox.cancel_pending_before(3, reason="explicit_replace")

            self.assertEqual(cancelled, 1)
            self.assertEqual(
                [record["state"] for record in inbox.records()],
                ["cancelled", "claimed"],
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

    def test_state_lists_all_current_source_siblings_after_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            state = Path(directory) / "state.json"
            first = inbox.enqueue(
                "first",
                item_metadata(7, "multi", 1, target="login"),
                "queue_project_work",
            )
            inbox.enqueue(
                "second",
                item_metadata(7, "multi", 2, target="search"),
                "queue_project_work",
            )
            inbox.observe_claim(first, provider_turn_seen=True)

            sync_deliverable_state(str(state), inbox)

            payload = json.loads(state.read_text())
            self.assertEqual(
                [item["intent_id"] for item in payload["source_command_intents"]],
                ["multi:item:1", "multi:item:2"],
            )
            self.assertEqual(
                [item["state"] for item in payload["source_command_intents"]],
                ["acked", "pending"],
            )
            self.assertNotIn("source_text", payload["source_command_intents"][0])
            inbox.close()

    def test_state_recovers_latest_durable_command_without_regressing_newer_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            state = Path(directory) / "state.json"
            latest = {
                **metadata(7, "seven"),
                "agent_prompt": "Recovered prompt",
                "provider": "codex",
            }
            inbox.enqueue(latest["agent_prompt"], latest, "continue_current")

            sync_deliverable_state(str(state), inbox)

            recovered = json.loads(state.read_text())
            self.assertEqual(recovered["relay_command_seq"], 7)
            self.assertEqual(recovered["relay_command_id"], "seven")
            self.assertEqual(recovered["agent_prompt"], "Recovered prompt")

            state.write_text(json.dumps({
                "relay_command_seq": 8,
                "relay_command_id": "eight",
                "source_text": "new turn not enqueued yet",
            }))
            sync_deliverable_state(str(state), inbox)

            current = json.loads(state.read_text())
            self.assertEqual(current["relay_command_seq"], 8)
            self.assertEqual(current["relay_command_id"], "eight")
            self.assertEqual(current["source_text"], "new turn not enqueued yet")

    def test_materialize_orders_by_command_sequence_then_within_turn_order(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
                command = str(Path(directory) / "ready")
                meta = command + ".meta"
                queued = [
                    ("seq two", item_metadata(2, "two", 1, target="later")),
                    ("seq one second", item_metadata(1, "one", 2, target="second")),
                    ("seq one first", item_metadata(1, "one", 1, target="first")),
                ]
                for prompt, item in queued:
                    item["provider"] = provider
                    inbox.enqueue(prompt, item, "queue_project_work")

                first = inbox.materialize_next(
                    command_path=command,
                    metadata_path=meta,
                    transport="app-owned",
                )

                self.assertEqual(Path(command).read_text(), "seq one first")
                self.assertEqual(first["relay_command_seq"], 1)
                self.assertEqual(first["within_turn_order"], 1)
                self.assertEqual(first["provider"], provider)

    def test_partial_cancellation_releases_leased_item_and_requeues_survivor(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            command = str(Path(directory) / "ready")
            meta = command + ".meta"
            login = item_metadata(1, "one", 1, target="login")
            search = item_metadata(1, "one", 2, target="search")
            inbox.enqueue("fix login", login, "queue_project_work")
            inbox.enqueue("add search", search, "queue_project_work")
            inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )

            cancelled = inbox.cancel_scoped(
                {
                    "cancellation_scope": "item",
                    "target_intent_ids": [login["intent_id"]],
                },
                command_path=command,
                metadata_path=meta,
            )
            survivor = inbox.materialize_next(
                command_path=command,
                metadata_path=meta,
                transport="app-owned",
            )

            self.assertEqual(cancelled, [login["intent_id"]])
            self.assertEqual(Path(command).read_text(), "add search")
            self.assertEqual(survivor["intent_id"], search["intent_id"])
            self.assertEqual(
                [(record["intent_id"], record["state"]) for record in inbox.records()],
                [(login["intent_id"], "cancelled"), (search["intent_id"], "delivered")],
            )


if __name__ == "__main__":
    unittest.main()
