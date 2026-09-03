from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from intent_inbox import IntentInbox  # noqa: E402
from provider_turn_broker import ProviderTurnBroker  # noqa: E402
import relay_completion_hook  # noqa: E402


OWNERSHIP = {
    "app_session_id": "app-session",
    "recovery_generation": "generation-2",
    "actor_role": "foreground_pm",
    "foreground_gate_handle": "gate-2",
}


def turn_record(provider: str, *, intent_id: str = "intent-1") -> dict:
    return {
        **OWNERSHIP,
        "state": "active",
        "origin": "relay",
        "provider": provider,
        "provider_session_id": f"provider-session-{provider}",
        "session_id": f"native-session-{provider}",
        "turn_id": f"native-turn-{provider}",
        "intent_id": intent_id,
        "relay_command_seq": 1,
        "relay_command_id": f"command-{provider}",
        "created_at": 100.0,
    }


class ProviderTurnBrokerTests(unittest.TestCase):
    def test_schema_migrates_manual_submission_evidence_columns(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            connection = sqlite3.connect(database)
            connection.execute(
                """
                CREATE TABLE provider_turns (
                    turn_id TEXT PRIMARY KEY,
                    owner_id TEXT NOT NULL,
                    app_session_id TEXT NOT NULL,
                    recovery_generation TEXT NOT NULL,
                    actor_role TEXT NOT NULL,
                    foreground_gate_handle TEXT NOT NULL,
                    provider TEXT,
                    provider_session_id TEXT,
                    native_session_id TEXT NOT NULL,
                    native_turn_id TEXT,
                    local_turn_seq INTEGER,
                    origin TEXT NOT NULL,
                    intent_id TEXT,
                    command_seq INTEGER,
                    command_id TEXT,
                    state TEXT NOT NULL,
                    release_reason TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            connection.commit()
            connection.close()

            broker = ProviderTurnBroker(database)
            self.addCleanup(broker.close)
            migrated = sqlite3.connect(database)
            columns = {
                row[1]
                for row in migrated.execute("PRAGMA table_info(provider_turns)").fetchall()
            }
            migrated.close()
            self.assertTrue({
                "manual_submission_id",
                "manual_submit_evidence_source",
            }.issubset(columns))

    def test_schema_projection_and_generation_isolation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            projection = os.path.join(temp_dir, "provider-turns-v2.json")
            broker = ProviderTurnBroker(database, projection_path=projection)
            self.addCleanup(broker.close)

            current = turn_record("codex")
            current["manual_submission_id"] = "manual-boundary-1"
            current["manual_submit_evidence_source"] = "relay_terminal_manual_submit"
            stale = {
                **turn_record("claude", intent_id="intent-stale"),
                "recovery_generation": "generation-1",
            }
            self.assertTrue(broker.activate(current, now=100.0))
            self.assertTrue(broker.activate(stale, now=101.0))

            self.assertEqual(len(broker.table_records("provider_turn_owners")), 2)
            self.assertEqual(len(broker.table_records("provider_turns")), 2)
            transitions = broker.table_records("provider_turn_transitions")
            self.assertEqual([row["event_type"] for row in transitions], [
                "prompt_submitted",
                "prompt_submitted",
            ])
            payload = json.loads(Path(projection).read_text())
            self.assertEqual(payload["schema_version"], 2)
            self.assertEqual(
                {row["recovery_generation"] for row in payload["records"]},
                {"generation-1", "generation-2"},
            )
            current_projection = next(
                row for row in payload["records"]
                if row["recovery_generation"] == "generation-2"
            )
            self.assertEqual(current_projection["manual_submission_id"], "manual-boundary-1")
            self.assertEqual(
                current_projection["manual_submit_evidence_source"],
                "relay_terminal_manual_submit",
            )
            self.assertNotIn("prompt", Path(projection).read_text())

    def test_claim_ack_recovery_and_cancellation_share_inbox_transactions(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            projection = os.path.join(temp_dir, "provider-turns-v2.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(database, provider_turn_projection_path=projection)
            broker = ProviderTurnBroker(database, projection_path=projection)
            self.addCleanup(broker.close)
            self.addCleanup(inbox.close)
            command = {
                "relay_command_seq": 1,
                "relay_command_id": "command-codex",
                "intent_id": "intent-1",
            }
            stored = inbox.enqueue("private prompt", command, "continue_current")
            self.assertTrue(broker.activate(turn_record("codex"), now=100.0))

            self.assertIsNotNone(inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            ))
            self.assertTrue(inbox.observe_claim(stored, provider_turn_seen=True))
            event_types = {
                row["event_type"]
                for row in broker.table_records("provider_turn_transitions")
            }
            self.assertTrue({
                "intent_claimed",
                "intent_acknowledged",
                "prompt_submitted",
            }.issubset(event_types))

            self.assertEqual(inbox.cancel_scoped({
                "intent_id": "cancel-1",
                "cancellation_scope": "item",
                "target_intent_ids": ["intent-1"],
            }), ["intent-1"])
            self.assertEqual(broker.table_records("provider_turns")[0]["state"], "cancelled")
            self.assertIn(
                "intent_cancelled",
                {
                    row["event_type"]
                    for row in broker.table_records("provider_turn_transitions")
                },
            )

    def test_next_intent_waits_for_predecessor_authoritative_effect(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            projection = os.path.join(temp_dir, "provider-turns-v2.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(database, provider_turn_projection_path=projection)
            broker = ProviderTurnBroker(database, projection_path=projection)
            self.addCleanup(broker.close)
            self.addCleanup(inbox.close)
            first = {
                "relay_command_seq": 1,
                "relay_command_id": "command-1",
                "intent_id": "intent-1",
            }
            second = {
                "relay_command_seq": 2,
                "relay_command_id": "command-2",
                "intent_id": "intent-2",
            }
            turn = {
                **turn_record("codex"),
                "relay_command_id": "command-1",
            }
            stored = inbox.enqueue("private first", first, "continue_current")
            inbox.enqueue("private second", second, "continue_current")
            self.assertIsNotNone(inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            ))
            self.assertTrue(broker.activate(turn, now=100.0))
            self.assertTrue(inbox.observe_claim(stored, provider_turn_seen=True, now=100.1))
            os.unlink(command_path)
            os.unlink(metadata_path)

            self.assertIsNone(inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            ))
            self.assertTrue(broker.transition(
                turn,
                to_state="completed_final",
                event_type="provider_completed",
                release_reason="provider_stop",
                now=101.0,
            ))
            self.assertIsNone(inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            ))

            reservation = broker.reserve_effect(turn, now=101.1)
            self.assertTrue(reservation.accepted)
            self.assertTrue(broker.authorize_effect_delivery(reservation.effect_id, now=101.2))
            broker.finish_effect(reservation.effect_id, delivered=True, now=101.3)

            materialized = inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            )
            self.assertEqual(materialized["intent_id"], "intent-2")

    def test_failed_authoritative_effect_releases_successor(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            projection = os.path.join(temp_dir, "provider-turns-v2.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(database, provider_turn_projection_path=projection)
            broker = ProviderTurnBroker(database, projection_path=projection)
            self.addCleanup(broker.close)
            self.addCleanup(inbox.close)
            first = {
                "relay_command_seq": 1,
                "relay_command_id": "command-1",
                "intent_id": "intent-1",
            }
            second = {
                "relay_command_seq": 2,
                "relay_command_id": "command-2",
                "intent_id": "intent-2",
            }
            turn = {
                **turn_record("codex"),
                "relay_command_id": "command-1",
            }
            stored = inbox.enqueue("private first", first, "continue_current")
            inbox.enqueue("private second", second, "continue_current")
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            )
            self.assertTrue(broker.activate(turn, now=100.0))
            self.assertTrue(inbox.observe_claim(stored, provider_turn_seen=True, now=100.1))
            os.unlink(command_path)
            os.unlink(metadata_path)
            self.assertTrue(broker.transition(
                turn,
                to_state="completed_final",
                event_type="provider_completed",
                release_reason="provider_stop",
                now=101.0,
            ))
            reservation = broker.reserve_effect(turn, now=101.1)
            self.assertTrue(reservation.accepted)
            self.assertTrue(broker.authorize_effect_delivery(reservation.effect_id, now=101.2))
            broker.finish_effect(reservation.effect_id, delivered=False, now=101.3)

            materialized = inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            )
            self.assertEqual(materialized["intent_id"], "intent-2")

    def test_concurrent_effect_reservations_accept_exactly_one(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            owner = ProviderTurnBroker(database)
            self.addCleanup(owner.close)
            command = turn_record("codex")
            self.assertTrue(owner.activate(command, now=100.0))
            brokers = [ProviderTurnBroker(database), ProviderTurnBroker(database)]
            for broker in brokers:
                self.addCleanup(broker.close)
            barrier = threading.Barrier(2)
            results = []

            def reserve(broker: ProviderTurnBroker) -> None:
                barrier.wait()
                results.append(broker.reserve_effect(command))

            threads = [threading.Thread(target=reserve, args=(broker,)) for broker in brokers]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=2)

            self.assertEqual(sum(result.accepted for result in results), 1)
            self.assertEqual(len(owner.table_records("provider_turn_effects")), 1)

    def test_inbox_restart_records_recovery_without_resuming_a_stale_owner(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            projection = os.path.join(temp_dir, "provider-turns-v2.json")
            command_path = os.path.join(temp_dir, "voice_cmd_ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(database, provider_turn_projection_path=projection)
            broker = ProviderTurnBroker(database, projection_path=projection)
            command = {
                "relay_command_seq": 1,
                "relay_command_id": "command-codex",
                "intent_id": "intent-1",
            }
            stored = inbox.enqueue("private prompt", command, "continue_current")
            broker.activate(turn_record("codex"), now=100.0)
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="test",
            )
            inbox.observe_claim(stored, provider_turn_seen=False)
            inbox.close()

            recovered = IntentInbox(database, provider_turn_projection_path=projection)
            try:
                self.assertEqual(recovered.records()[0]["state"], "review_required")
                self.assertEqual(recovered.reconcile_terminal_claims(), 0)
                event_types = {
                    row["event_type"]
                    for row in broker.table_records("provider_turn_transitions")
                }
                self.assertIn("inbox_recovered", event_types)
                self.assertEqual(broker.table_records("provider_turns")[0]["state"], "active")
                stale_generation = {
                    **turn_record("codex"),
                    "recovery_generation": "generation-1",
                }
                self.assertIsNone(broker.state_for(stale_generation))
            finally:
                recovered.close()
                broker.close()

    def test_termination_is_scoped_to_exact_owner_generation_and_provider_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            database = os.path.join(temp_dir, "inbox.sqlite3")
            broker = ProviderTurnBroker(database)
            try:
                current = turn_record("codex")
                stale = {
                    **turn_record("claude", intent_id="intent-stale"),
                    "recovery_generation": "generation-1",
                }
                broker.activate(current, now=100.0)
                broker.activate(stale, now=100.0)

                self.assertEqual(broker.terminate_owner(
                    OWNERSHIP,
                    provider_session_id="provider-session-codex",
                    release_reason="app_teardown",
                    event_id="teardown-current",
                    now=101.0,
                ), 1)
                self.assertEqual(broker.state_for(current), "terminated")
                self.assertEqual(broker.state_for(stale), "active")
                self.assertEqual(broker.terminate_owner(
                    OWNERSHIP,
                    provider_session_id="provider-session-codex",
                    release_reason="app_teardown",
                    event_id="teardown-current",
                    now=102.0,
                ), 0)
            finally:
                broker.close()

    def test_codex_and_claude_duplicate_completion_faults_emit_one_effect(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                state_path = os.path.join(temp_dir, "voice_command_state.json")
                claim_path = os.path.join(temp_dir, "voice_cmd_claimed.json")
                turns_path = os.path.join(temp_dir, "voice_provider_turns.json")
                command = {
                    "relay_command_seq": 1,
                    "relay_command_id": f"command-{provider}",
                    "intent_id": "intent-1",
                    "agent_prompt": "bounded prompt",
                    "provider": provider,
                }
                Path(state_path).write_text(json.dumps(command))
                Path(claim_path).write_text(json.dumps(command))
                prompt = {
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": f"native-session-{provider}",
                    "turn_id": f"native-turn-{provider}",
                    "prompt": "bounded prompt",
                }
                stop = {
                    "hook_event_name": "Stop",
                    "session_id": f"native-session-{provider}",
                    "turn_id": f"native-turn-{provider}",
                    "last_assistant_message": "authoritative final",
                }
                delivered = []
                with mock.patch.dict(os.environ, {
                    "RELAY_APP_SESSION_ID": OWNERSHIP["app_session_id"],
                    "RELAY_RECOVERY_GENERATION": OWNERSHIP["recovery_generation"],
                    "RELAY_ACTOR_ROLE": OWNERSHIP["actor_role"],
                    "RELAY_FOREGROUND_GATE_HANDLE": OWNERSHIP["foreground_gate_handle"],
                    "RELAY_RUNNER_PROVIDER": provider,
                    "RELAY_PROVIDER_SESSION_ID": f"provider-session-{provider}",
                }):
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        prompt,
                        claim_path=claim_path,
                        state_path=state_path,
                        turns_path=turns_path,
                        stderr=io.StringIO(),
                    ))
                    self.assertTrue(relay_completion_hook.handle_hook_payload(
                        stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        stderr=io.StringIO(),
                    ))
                    self.assertFalse(relay_completion_hook.handle_hook_payload(
                        stop,
                        state_path=state_path,
                        turns_path=turns_path,
                        write_control=lambda payload: delivered.append(payload) or True,
                        stderr=io.StringIO(),
                    ))

                self.assertEqual(len(delivered), 1)
                database = turns_path + ".sqlite3"
                broker = ProviderTurnBroker(database)
                try:
                    first = broker.reserve_effect(delivered[0])
                    second = broker.reserve_effect(delivered[0])
                    self.assertTrue(first.accepted)
                    self.assertFalse(second.accepted)
                    self.assertEqual(second.reason, "duplicate")
                    self.assertEqual(len(broker.table_records("provider_turn_effects")), 1)
                finally:
                    broker.close()

    def test_codex_and_claude_revocation_rejects_effect_after_completion(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as temp_dir:
                database = os.path.join(temp_dir, "inbox.sqlite3")
                projection = os.path.join(temp_dir, "provider-turns-v2.json")
                inbox = IntentInbox(database, provider_turn_projection_path=projection)
                broker = ProviderTurnBroker(database, projection_path=projection)
                try:
                    record = turn_record(provider)
                    inbox.enqueue("private prompt", record, "continue_current")
                    self.assertTrue(broker.activate(record, now=100.0))
                    self.assertTrue(broker.transition(
                        record,
                        to_state="completed_final",
                        event_type="provider_completed",
                        release_reason="provider_stop",
                        now=101.0,
                    ))
                    self.assertEqual(inbox.cancel_scoped({
                        "intent_id": "cancel-current",
                        "cancellation_scope": "item",
                        "target_intent_ids": [record["intent_id"]],
                    }), [record["intent_id"]])

                    reservation = broker.reserve_effect(record, now=102.0)

                    self.assertFalse(reservation.accepted)
                    self.assertEqual(reservation.reason, "turn_revoked")
                    self.assertEqual(broker.table_records("provider_turn_effects"), [])
                finally:
                    broker.close()
                    inbox.close()

    def test_codex_and_claude_revocation_after_reservation_fails_effect(self):
        for provider in ("codex", "claude"):
            for relationship in ("cancellation", "replacement"):
                with self.subTest(provider=provider, relationship=relationship), \
                        tempfile.TemporaryDirectory() as temp_dir:
                    database = os.path.join(temp_dir, "inbox.sqlite3")
                    projection = os.path.join(temp_dir, "provider-turns-v2.json")
                    inbox = IntentInbox(database, provider_turn_projection_path=projection)
                    broker = ProviderTurnBroker(database, projection_path=projection)
                    try:
                        record = turn_record(provider)
                        inbox.enqueue("private prompt", record, "continue_current")
                        self.assertTrue(broker.activate(record, now=100.0))
                        self.assertTrue(broker.transition(
                            record,
                            to_state="completed_final",
                            event_type="provider_completed",
                            release_reason="provider_stop",
                            now=101.0,
                        ))
                        reservation = broker.reserve_effect(record, now=102.0)
                        self.assertTrue(reservation.accepted)
                        self.assertIsNotNone(reservation.effect_id)
                        self.assertEqual(inbox.cancel_scoped({
                            "intent_id": f"{relationship}-current",
                            "cancellation_scope": "item",
                            "target_intent_ids": [record["intent_id"]],
                        }), [record["intent_id"]])

                        self.assertFalse(broker.authorize_effect_delivery(
                            reservation.effect_id or "",
                            now=103.0,
                        ))
                        broker.finish_effect(
                            reservation.effect_id or "",
                            delivered=True,
                            now=104.0,
                        )

                        effects = broker.table_records("provider_turn_effects")
                        self.assertEqual(len(effects), 1)
                        self.assertEqual(effects[0]["state"], "failed")
                    finally:
                        broker.close()
                        inbox.close()

    def test_codex_and_claude_authorization_wins_the_revocation_race(self):
        for provider in ("codex", "claude"):
            for relationship in ("cancellation", "replacement"):
                with self.subTest(provider=provider, relationship=relationship), \
                        tempfile.TemporaryDirectory() as temp_dir:
                    database = os.path.join(temp_dir, "inbox.sqlite3")
                    inbox = IntentInbox(database)
                    broker = ProviderTurnBroker(database)
                    try:
                        record = turn_record(provider)
                        inbox.enqueue("private prompt", record, "continue_current")
                        self.assertTrue(broker.activate(record, now=100.0))
                        reservation = broker.reserve_effect(record, now=101.0)
                        self.assertTrue(reservation.accepted)
                        self.assertTrue(broker.authorize_effect_delivery(
                            reservation.effect_id or "",
                            now=102.0,
                        ))
                        self.assertEqual(inbox.cancel_scoped({
                            "intent_id": f"{relationship}-current",
                            "cancellation_scope": "item",
                            "target_intent_ids": [record["intent_id"]],
                        }), [record["intent_id"]])

                        broker.finish_effect(
                            reservation.effect_id or "",
                            delivered=True,
                            now=103.0,
                        )

                        effects = broker.table_records("provider_turn_effects")
                        self.assertEqual(len(effects), 1)
                        self.assertEqual(effects[0]["state"], "delivered")
                    finally:
                        broker.close()
                        inbox.close()


if __name__ == "__main__":
    unittest.main()
