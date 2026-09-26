from __future__ import annotations

import json
from pathlib import Path
import sys
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services"))
try:
    import numpy  # noqa: F401
except ModuleNotFoundError:
    # Match the voice-bridge harness only when optional audio dependencies are absent.
    sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda samples: samples, int16=object()))

from command_actions import classify_command
from intent_arbitration import ActiveWork
from intent_qualification import qualify_intent
from relay_authorization import allowed_mutations_for_metadata
from voice_bridge import _resolve_voice_work_items


class IntentQualificationTests(unittest.TestCase):
    def test_labelled_development_regressions(self):
        corpus = json.loads((ROOT / "tests/fixtures/intent_qualification.json").read_text())
        for case in corpus["cases"]:
            with self.subTest(case=case["id"]):
                action = classify_command(case["text"])
                hint = qualify_intent(case["text"], context=case["context"])
                self.assertEqual(action.kind, case["expected_action_kind"])
                self.assertEqual(hint.bucket, case["expected_bucket"])

    def test_assent_never_invents_authority_from_unverified_context(self):
        for context in ([], [{"role": "assistant", "content": "I could fix login."}]):
            hint = qualify_intent("Yes, do that", context=context)
            self.assertTrue(hint.unresolved)
            self.assertEqual(hint.bucket, "discussion")
            self.assertEqual(hint.reason, "context_required")

    def test_whole_turn_revision_is_preserved_before_split_for_both_providers(self):
        text = "Can you build this? I only want to discuss feasibility, do not implement it."
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                items = _resolve_voice_work_items(
                    text,
                    {"relay_command_seq": 7, "relay_command_id": "revision", "provider": provider},
                    repo_path="/tmp/example", active_work=(ActiveWork("accepted", ("repository",)),),
                )
                self.assertEqual(len(items), 1)
                resolved = items[0]
                self.assertEqual(resolved["item"].source_text, text)
                self.assertEqual(resolved["disposition"].authorization_effect.value, "preserve")
                self.assertEqual(allowed_mutations_for_metadata(resolved["metadata"]), [])
                hint = resolved["metadata"]["intent_qualification"]
                self.assertEqual((hint["command_seq"], hint["command_id"]), (7, "revision"))
                self.assertEqual(hint["bucket"], "discussion")
                self.assertIn(text, resolved["prompt"])
                self.assertIn("may correct this hint", resolved["prompt"])

    def test_later_discussion_revision_overrides_ticket_only_exception(self):
        text = "Create a ticket. Do not implement it. I only want to discuss feasibility."
        items = _resolve_voice_work_items(text, {"relay_command_seq": 8, "relay_command_id": "revised"}, repo_path="/tmp/example")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["action"].kind, "conversation")
        self.assertEqual(allowed_mutations_for_metadata(items[0]["metadata"]), [])

    def test_mixed_scope_is_deferred_without_losing_original_order(self):
        text = "Open Chrome and fix login"
        items = _resolve_voice_work_items(text, {"relay_command_seq": 8, "relay_command_id": "mixed"}, repo_path="/tmp/example")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["item"].source_text, text)
        self.assertTrue(items[0]["metadata"]["intent_qualification"]["mixed"])
        self.assertTrue(items[0]["metadata"]["intent_qualification"]["unresolved"])
        self.assertEqual(allowed_mutations_for_metadata(items[0]["metadata"]), [])

    def test_drafting_permission_does_not_grant_dispatch_or_implementation(self):
        for text in (
            "Create a ticket to fix login; do not dispatch it",
            "Create a ticket for login but do not implement it",
            "Create a ticket for login, backlog only",
        ):
            with self.subTest(text=text):
                items = _resolve_voice_work_items(text, {"relay_command_seq": 9, "relay_command_id": "draft"}, repo_path="/tmp/example")
                self.assertEqual(len(items), 1)
                self.assertEqual(items[0]["metadata"]["intent_qualification"]["bucket"], "task")
                allowed = allowed_mutations_for_metadata(items[0]["metadata"])
                self.assertEqual(len(allowed), 1)
                self.assertEqual(allowed[0]["kind"], "orchestrator_action")
                self.assertIn("create_ticket", allowed[0]["action_kinds"])
                self.assertNotIn("request_worker", allowed[0]["action_kinds"])

    def test_bucket_alone_never_grants_mutation(self):
        for bucket in ("task", "action", "discussion"):
            self.assertEqual(allowed_mutations_for_metadata({
                "action": "conversation", "source_text": "Discuss login",
                "intent_qualification": {"bucket": bucket},
            }), [])

    def test_control_path_is_separate(self):
        for text in ("__TTS_STOP__", "Cancel RR-400"):
            self.assertIsNone(qualify_intent(text).bucket)


if __name__ == "__main__":
    unittest.main()
