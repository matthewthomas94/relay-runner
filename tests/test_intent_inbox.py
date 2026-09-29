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
from provider_turn_broker import ProviderTurnBroker  # noqa: E402


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
    def test_new_session_voice_retires_stale_foreground_without_replaying_it(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "inbox.sqlite3"
                projection = Path(directory) / "turns.json"
                command = str(Path(directory) / "ready")
                meta = command + ".meta"
                inbox = IntentInbox(path, provider_turn_projection_path=projection)
                old = inbox.enqueue("old claimed", {
                    **metadata(1, "old"), "provider": provider,
                    "recovery_generation": "old-generation",
                }, "continue_current")
                inbox.observe_claim(old, provider_turn_seen=False)
                inbox.enqueue("old pending", {
                    **metadata(2, "pending"), "recovery_generation": "old-generation",
                }, "continue_current")
                inbox.enqueue("old work request", {
                    **metadata(3, "work", "queue_project_work"),
                    "recovery_generation": "old-generation",
                }, "queue_project_work")
                inbox.enqueue("worker", {
                    **metadata(4, "worker", "run_sidecar"),
                    "recovery_generation": "old-generation",
                }, "run_sidecar")
                inbox.close()

                inbox = IntentInbox(path, provider_turn_projection_path=projection)
                self.assertEqual(inbox.recovery_blocker()["command_seq"], 1)
                Path(command).write_text("old pending")
                Path(meta).write_text(json.dumps({"intent_id": "intent-2"}))
                fresh = {**metadata(5, "fresh"), "recovery_generation": "new-generation"}
                self.assertEqual(inbox.retire_stale_foreground(
                    "new-generation", command_path=command, metadata_path=meta,
                ), 3)
                self.assertFalse(Path(command).exists())
                self.assertFalse(Path(meta).exists())
                self.assertIsNone(inbox.recovery_blocker())
                self.assertEqual([r["state"] for r in inbox.records()],
                                 ["cancelled", "cancelled", "cancelled", "pending"])
                inbox.enqueue("fresh", fresh, "continue_current")
                delivered = inbox.materialize_next(
                    command_path=command, metadata_path=meta, transport="test",
                )
                self.assertEqual(delivered["relay_command_seq"], 5)
                self.assertEqual(Path(command).read_text(), "fresh")
                inbox.close()

    def test_stale_retirement_preserves_current_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            inbox.enqueue("current", {
                **metadata(1, "current"), "recovery_generation": "same",
            }, "continue_current")
            self.assertEqual(inbox.retire_stale_foreground(
                "same", before_command_seq=2,
                command_path=str(Path(directory) / "ready"),
                metadata_path=str(Path(directory) / "ready.meta"),
            ), 0)
            self.assertEqual(inbox.records()[0]["state"], "pending")
            inbox.close()

    def test_restart_retirement_requires_exact_claim_and_never_cancels_acknowledged_work(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            claim = inbox.enqueue("first", metadata(104, "old"), "continue_current")
            self.assertFalse(inbox.retire_replaced_claim(claim), "Pending work must never be discarded")
            inbox.observe_claim(claim, provider_turn_seen=False)
            for field in ("intent_id", "relay_command_id", "intent_delivery_id", "intent_claim_id", "intent_ack_id"):
                self.assertFalse(inbox.retire_replaced_claim({**claim, field: "wrong"}))
            inbox.observe_claim(claim, provider_turn_seen=True)
            self.assertFalse(inbox.retire_replaced_claim(claim))
            self.assertEqual(inbox.records()[0]["state"], "acked")
            inbox.close()

    def test_persisted_blocker_requires_exact_explicit_skip_and_preserves_queue(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "inbox.sqlite3"
                command = str(Path(directory) / "ready")
                state = str(Path(directory) / "state.json")
                inbox = IntentInbox(path)
                first = inbox.enqueue("uncertain", {**metadata(94, "old"), "provider": provider}, "continue_current")
                for seq in (95, 96):
                    inbox.enqueue(str(seq), metadata(seq, str(seq)), "continue_current")
                inbox.materialize_next(command_path=command, metadata_path=command + ".meta", transport="test")
                inbox.observe_claim(first, provider_turn_seen=False)
                os.unlink(command)
                os.unlink(command + ".meta")
                inbox.close()
                inbox = IntentInbox(path)
                sync_deliverable_state(state, inbox)
                blocker = json.loads(Path(state).read_text())["inbox_recovery_blocker"]
                self.assertEqual(blocker["command_seq"], 94)
                self.assertNotIn("prompt", blocker)
                self.assertFalse(inbox.skip_recovery_blocker({**blocker, "intent_id": "wrong"}))
                self.assertIsNone(inbox.materialize_next(command_path=command, metadata_path=command + ".meta", transport="test"))
                self.assertTrue(inbox.skip_recovery_blocker(blocker))
                self.assertFalse(inbox.skip_recovery_blocker(blocker))
                self.assertEqual([r["state"] for r in inbox.records()], ["cancelled", "pending", "pending"])
                self.assertEqual(inbox.records()[0]["prompt"], "uncertain")
                sync_deliverable_state(state, inbox)
                self.assertIsNone(json.loads(Path(state).read_text())["inbox_recovery_blocker"])
                next_item = inbox.materialize_next(command_path=command, metadata_path=command + ".meta", transport="test")
                self.assertEqual(next_item["relay_command_seq"], 95)
                inbox.observe_claim(next_item, provider_turn_seen=True)
                os.unlink(command)
                os.unlink(command + ".meta")
                last_item = inbox.materialize_next(command_path=command, metadata_path=command + ".meta", transport="test")
                self.assertEqual(last_item["relay_command_seq"], 96)
                inbox.close()

    def test_recovery_skip_rejects_late_acknowledgement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            inbox = IntentInbox(path)
            first = inbox.enqueue("first", metadata(94, "old"), "continue_current")
            inbox.observe_claim(first, provider_turn_seen=False)
            inbox.close()
            inbox = IntentInbox(path)
            blocker = inbox.recovery_blocker()
            self.assertIsNotNone(blocker)
            inbox.observe_claim(first, provider_turn_seen=True)
            self.assertFalse(inbox.skip_recovery_blocker(blocker))
            self.assertEqual(inbox.records()[0]["state"], "acked")
            inbox.close()

    def test_recovery_skip_does_not_cancel_a_known_provider_turn(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "inbox.sqlite3"
                projection = Path(directory) / "turns.json"
                inbox = IntentInbox(path, provider_turn_projection_path=projection)
                first = inbox.enqueue("uncertain", metadata(94, "old"), "continue_current")
                inbox.observe_claim(first, provider_turn_seen=False)
                inbox.close()
                inbox = IntentInbox(path, provider_turn_projection_path=projection)
                blocker = inbox.recovery_blocker()
                broker = ProviderTurnBroker(path, projection_path=projection)
                self.assertTrue(broker.activate({
                    "app_session_id": "app", "recovery_generation": "1",
                    "actor_role": "foreground_pm", "foreground_gate_handle": "gate",
                    "state": "active", "origin": "relay", "provider": provider,
                    "provider_session_id": "provider", "session_id": "native",
                    "turn_id": "turn", "intent_id": first["intent_id"],
                    "relay_command_seq": 94, "relay_command_id": "old", "created_at": 100,
                }, now=100))
                self.assertFalse(inbox.skip_recovery_blocker(blocker))
                self.assertFalse(inbox.retire_replaced_claim(first))
                self.assertEqual(inbox.records()[0]["state"], "review_required")
                self.assertEqual(broker.table_records("provider_turns")[0]["state"], "active")
                broker.close()
                inbox.close()

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

    def test_completed_old_turn_without_reply_does_not_block_new_command(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "inbox.sqlite3"
                inbox = IntentInbox(path, provider_turn_projection_path=Path(directory) / "turns.json")
                old = inbox.enqueue("old", {**metadata(1, "old"), "provider": provider}, "continue_current")
                turn = {
                    "app_session_id": "old-app", "recovery_generation": "old-generation",
                    "actor_role": "foreground_pm", "foreground_gate_handle": "old-gate",
                    "origin": "relay", "provider": provider,
                    "provider_session_id": "old-provider", "session_id": "old-native",
                    "turn_id": "old-turn", "intent_id": old["intent_id"],
                    "relay_command_seq": 1, "relay_command_id": "old",
                }
                broker = ProviderTurnBroker(path)
                self.assertTrue(broker.activate(turn, now=1))
                self.assertTrue(broker.transition(
                    turn, to_state="completed_final", event_type="provider_final",
                    release_reason="final", now=2,
                ))
                inbox.observe_claim(old, provider_turn_seen=True)
                inbox.enqueue("new", {**metadata(2, "new"), "provider": provider}, "continue_current")

                command = str(Path(directory) / "ready")
                delivered = inbox.materialize_next(
                    command_path=command, metadata_path=command + ".meta", transport="test",
                )
                self.assertEqual(delivered["relay_command_seq"], 2)
                self.assertEqual(Path(command).read_text(), "new")
                broker.close()
                inbox.close()

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
