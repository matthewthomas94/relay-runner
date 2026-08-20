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

from continuity_incidents import opaque_identifier  # noqa: E402
from continuity_resume import PLEASE_REPEAT_TEXT, plan_continuity_resume  # noqa: E402
from intent_inbox import IntentInbox  # noqa: E402


def incident(command_id: str | None = "command-one", generation: str = "generation-7"):
    return {
        "command_id": (
            opaque_identifier("command", command_id) if command_id is not None else None
        ),
        "component": "command" if command_id else "speech_capture",
        "phase": "command_processing" if command_id else "capture",
        "recovery_generation": generation,
        "unavailable_capability": (
            None
            if command_id
            else "Relay Runner cannot capture speech for the active voice session."
        ),
    }


def record(state: str, *, order: int = 1, generation: str = "generation-7"):
    return {
        "ordinal": order,
        "intent_id": f"intent-{order}",
        "command_seq": 1,
        "command_id": "command-one",
        "within_turn_order": order,
        "state": state,
        "recovery_generation": generation,
    }


class ContinuityResumeDecisionTests(unittest.TestCase):
    def test_pretranscript_loss_has_one_deterministic_repeat_outcome(self):
        decision = plan_continuity_resume(
            incident(None), [], final_result="restored"
        )

        self.assertEqual(
            (decision.phase, decision.action, decision.reason),
            ("speech_not_captured", "ask_repeat", "no_durable_command"),
        )
        self.assertIn("Please repeat your request", PLEASE_REPEAT_TEXT)

    def test_pretranscript_loss_requires_matching_component_capability_evidence(self):
        handoff = incident(None)
        handoff["unavailable_capability"] = (
            "Relay Runner cannot turn captured speech into a command."
        )

        decision = plan_continuity_resume(handoff, [], final_result="restored")

        self.assertEqual(
            (decision.phase, decision.action, decision.reason),
            (
                "speech_not_captured",
                "foreground_review",
                "speech_loss_capability_mismatch",
            ),
        )

    def test_commandless_liveness_recovery_has_no_speech_outcome(self):
        for component, phase in (
            ("bridge", "delivery"),
            ("messenger", "component_liveness"),
            ("daemon", "component_liveness"),
            ("session", "session_liveness"),
        ):
            with self.subTest(component=component):
                decision = plan_continuity_resume(
                    {
                        **incident(None),
                        "component": component,
                        "phase": phase,
                    },
                    [],
                    final_result="restored",
                )

                self.assertEqual(
                    (decision.phase, decision.action, decision.reason),
                    (
                        "commandless_liveness",
                        "noop",
                        "no_command_resume_required",
                    ),
                )

    def test_handoff_waits_for_stable_health_result(self):
        decision = plan_continuity_resume(
            incident(), [record("pending")], final_result="circuit_open"
        )

        self.assertEqual(decision.action, "foreground_review")
        self.assertEqual(decision.reason, "stable_health_not_proven")

    def test_captured_and_delivered_unclaimed_commands_resume_original_intent(self):
        cases = (
            ("pending", "transcript_captured", "captured_not_delivered"),
            ("delivered", "delivered_unclaimed", "delivery_provably_unclaimed"),
        )
        for provider in ("codex", "claude"):
            for state, phase, reason in cases:
                with self.subTest(provider=provider, state=state):
                    command = record(state)
                    command["provider"] = provider
                    decision = plan_continuity_resume(
                        incident(), [command], final_result="restored"
                    )
                    self.assertEqual(
                        (decision.action, decision.phase, decision.reason, decision.intent_id),
                        ("resume_exact", phase, reason, "intent-1"),
                    )

    def test_claimed_and_ambiguous_commands_never_replay(self):
        for state in ("claimed", "review_required"):
            with self.subTest(state=state):
                decision = plan_continuity_resume(
                    incident(), [record(state)], final_result="restored"
                )
                self.assertEqual(decision.action, "foreground_review")
                self.assertEqual(decision.reason, "claim_may_have_started_effect")

    def test_acknowledged_command_reattaches_only_to_authoritative_provider_state(self):
        for provider_state in ("active", "completed_final"):
            with self.subTest(provider_state=provider_state):
                decision = plan_continuity_resume(
                    incident(),
                    [record("acked")],
                    final_result="restored",
                    provider_turn_state=provider_state,
                )
                self.assertEqual(decision.action, "reattach")
        ambiguous = plan_continuity_resume(
            incident(), [record("acked")], final_result="restored"
        )
        self.assertEqual(ambiguous.action, "foreground_review")

    def test_terminal_and_stale_completion_pressure_never_replay(self):
        for state in ("cancelled", "completed"):
            with self.subTest(state=state):
                decision = plan_continuity_resume(
                    incident(), [record(state)], final_result="restored"
                )
                self.assertEqual(decision.action, "noop")
        missing = plan_continuity_resume(
            incident("stale-command"), [record("pending")], final_result="restored"
        )
        self.assertEqual(missing.action, "foreground_review")

    def test_ordered_siblings_skip_revoked_item_and_resume_next_exact_intent(self):
        first = record("cancelled", order=1)
        second = record("pending", order=2)
        decision = plan_continuity_resume(
            incident(), [second, first], final_result="restored"
        )

        self.assertEqual(decision.action, "resume_exact")
        self.assertEqual(decision.intent_id, "intent-2")


class ContinuityResumeInboxTests(unittest.TestCase):
    @staticmethod
    def metadata(seq: int, command_id: str, generation: str = "generation-7"):
        return {
            "relay_command_seq": seq,
            "relay_command_id": command_id,
            "intent_id": f"intent-{seq}",
            "within_turn_order": 1,
            "recovery_generation": generation,
        }

    def test_exact_resume_is_generation_scoped_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            inbox = IntentInbox(Path(directory) / "inbox.sqlite3")
            inbox.enqueue("private prompt", self.metadata(1, "command-one"), "continue_current")

            self.assertFalse(inbox.resume_after_recovery(
                intent_id="intent-1", recovery_generation="generation-8"
            ))
            self.assertTrue(inbox.resume_after_recovery(
                intent_id="intent-1", recovery_generation="generation-7"
            ))
            self.assertFalse(inbox.resume_after_recovery(
                intent_id="intent-1", recovery_generation="generation-7"
            ))
            self.assertEqual(inbox.records()[0]["state"], "pending")

    def test_schema_v4_migration_preserves_generation_for_continuity_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            connection = sqlite3.connect(path)
            connection.executescript(
                """
                CREATE TABLE inbox_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                INSERT INTO inbox_meta(key, value) VALUES('schema_version', '4');
                CREATE TABLE intents (
                    ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                    intent_id TEXT NOT NULL UNIQUE,
                    command_seq INTEGER NOT NULL,
                    command_id TEXT NOT NULL,
                    within_turn_order INTEGER NOT NULL DEFAULT 1,
                    prompt TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    route TEXT NOT NULL,
                    state TEXT NOT NULL,
                    delivery_id TEXT NOT NULL UNIQUE,
                    claim_id TEXT,
                    ack_id TEXT,
                    created_at REAL NOT NULL,
                    delivered_at REAL,
                    claimed_at REAL,
                    acked_at REAL,
                    cancelled_at REAL,
                    transport TEXT,
                    lease_attempts INTEGER NOT NULL DEFAULT 0,
                    recovered_at REAL
                );
                """
            )
            metadata = self.metadata(1, "command-one")
            connection.execute(
                """
                INSERT INTO intents(
                    intent_id, command_seq, command_id, prompt, metadata_json,
                    route, state, delivery_id, created_at, delivered_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "intent-1",
                    1,
                    "command-one",
                    "private prompt",
                    json.dumps(metadata),
                    "continue_current",
                    "delivered",
                    "delivery:intent-1",
                    1.0,
                    2.0,
                ),
            )
            invalid_metadata = self.metadata(2, "command-two")
            invalid_metadata["recovery_generation"] = "generation 8"
            connection.execute(
                """
                INSERT INTO intents(
                    intent_id, command_seq, command_id, prompt, metadata_json,
                    route, state, delivery_id, created_at, delivered_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "intent-2",
                    2,
                    "command-two",
                    "another private prompt",
                    json.dumps(invalid_metadata),
                    "continue_current",
                    "delivered",
                    "delivery:intent-2",
                    1.0,
                    2.0,
                ),
            )
            connection.commit()
            connection.close()

            restarted = IntentInbox(path, hold_recovered_delivery=True)

            record, invalid_record = restarted.records()
            self.assertEqual(record["state"], "recovery_pending")
            self.assertEqual(record["recovery_generation"], "generation-7")
            self.assertEqual(invalid_record["recovery_generation"], "0")
            self.assertTrue(restarted.resume_after_recovery(
                intent_id="intent-1",
                recovery_generation="generation-7",
            ))
            self.assertFalse(restarted.resume_after_recovery(
                intent_id="intent-2",
                recovery_generation="generation-8",
            ))
            restarted.close()

    def test_restart_requeues_unclaimed_delivery_but_holds_claimed_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            command_path = str(Path(directory) / "ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(path)
            first = inbox.enqueue(
                "first", self.metadata(1, "command-one"), "continue_current"
            )
            inbox.enqueue("second", self.metadata(2, "command-two"), "continue_current")
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="codex",
            )
            inbox.observe_claim(first, provider_turn_seen=False)
            os.unlink(command_path)
            os.unlink(metadata_path)
            inbox.close()

            restarted = IntentInbox(path)
            self.assertEqual(
                [item["state"] for item in restarted.records()],
                ["review_required", "pending"],
            )
            self.assertIsNone(restarted.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="claude",
            ))

    def test_unclaimed_restart_preserves_order_and_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            command_path = str(Path(directory) / "ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(path)
            original = inbox.enqueue(
                "first", self.metadata(1, "command-one"), "continue_current"
            )
            inbox.enqueue("second", self.metadata(2, "command-two"), "continue_current")
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="codex",
            )
            os.unlink(command_path)
            os.unlink(metadata_path)
            inbox.close()

            restarted = IntentInbox(path)
            resumed = restarted.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="claude",
            )
            self.assertEqual(resumed["intent_id"], original["intent_id"])
            self.assertEqual(resumed["intent_delivery_id"], original["intent_delivery_id"])
            self.assertEqual(resumed["recovery_generation"], "generation-7")

    def test_continuity_restart_holds_delivery_until_stable_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "inbox.sqlite3"
            command_path = str(Path(directory) / "ready")
            metadata_path = command_path + ".meta"
            inbox = IntentInbox(path)
            inbox.enqueue("first", self.metadata(1, "command-one"), "continue_current")
            inbox.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="codex",
            )
            os.unlink(command_path)
            os.unlink(metadata_path)
            inbox.close()

            restarted = IntentInbox(path, hold_recovered_delivery=True)
            self.assertEqual(restarted.records()[0]["state"], "recovery_pending")
            self.assertIsNone(restarted.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="codex",
            ))
            self.assertTrue(restarted.resume_after_recovery(
                intent_id="intent-1",
                recovery_generation="generation-7",
            ))
            resumed = restarted.materialize_next(
                command_path=command_path,
                metadata_path=metadata_path,
                transport="codex",
            )
            self.assertEqual(resumed["intent_id"], "intent-1")

    def test_continuity_restart_holds_captured_pending_until_exact_generation_handoff(self):
        for transport in ("codex", "claude"):
            with self.subTest(transport=transport), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "inbox.sqlite3"
                command_path = str(Path(directory) / "ready")
                metadata_path = command_path + ".meta"
                inbox = IntentInbox(path)
                inbox.enqueue("first", self.metadata(1, "command-one"), "continue_current")
                inbox.close()

                restarted = IntentInbox(path, hold_recovered_delivery=True)
                self.assertEqual(restarted.records()[0]["state"], "recovery_pending")
                self.assertIsNone(restarted.materialize_next(
                    command_path=command_path,
                    metadata_path=metadata_path,
                    transport=transport,
                ))

                post_start = restarted.enqueue(
                    "second",
                    self.metadata(2, "command-two", generation="generation-8"),
                    "continue_current",
                )
                delivered = restarted.materialize_next(
                    command_path=command_path,
                    metadata_path=metadata_path,
                    transport=transport,
                )
                self.assertEqual(delivered["intent_id"], post_start["intent_id"])
                restarted.observe_claim(delivered, provider_turn_seen=True)
                os.unlink(command_path)
                os.unlink(metadata_path)

                self.assertFalse(restarted.resume_after_recovery(
                    intent_id="intent-1",
                    recovery_generation="generation-8",
                ))
                self.assertTrue(restarted.resume_after_recovery(
                    intent_id="intent-1",
                    recovery_generation="generation-7",
                ))
                resumed = restarted.materialize_next(
                    command_path=command_path,
                    metadata_path=metadata_path,
                    transport=transport,
                )
                self.assertEqual(resumed["intent_id"], "intent-1")
                restarted.close()


if __name__ == "__main__":
    unittest.main()
