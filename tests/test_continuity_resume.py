from __future__ import annotations

import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
