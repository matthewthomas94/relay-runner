from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from intent_arbitration import (  # noqa: E402
    ActiveWork,
    AuthorizationEffect,
    CancellationScope,
    IntentRoute,
    authorization_relationship_for,
    normalize_voice_work_items,
    resolve_intent_disposition,
    sidecar_eligible,
)


class IntentArbitrationTests(unittest.TestCase):
    def setUp(self):
        self.active = (ActiveWork("1:active", ("repository",)),)

    def resolve(self, text: str, kind: str = "conversation", reason: str = ""):
        return resolve_intent_disposition(
            intent_id="intent-2",
            action_kind=kind,
            action_reason=reason,
            source_text=text,
            active_work=self.active,
        )

    def test_additive_status_preserves_active_work(self):
        disposition = self.resolve("Also, what is the current status?")
        self.assertEqual(disposition.route, IntentRoute.CONTINUE_CURRENT)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.PRESERVE)
        self.assertEqual(disposition.target_work_ids, ("1:active",))

    def test_read_only_ticket_inspection_preserves_inspection_relationship(self):
        disposition = self.resolve("Is RR-325 done?", kind="inspect_ticket")

        self.assertEqual(disposition.route, IntentRoute.CONTINUE_CURRENT)
        self.assertEqual(
            authorization_relationship_for(disposition, fallback="inspection"),
            "inspection",
        )

    def test_negated_stop_status_preserves_active_work_even_with_cancel_hint(self):
        disposition = self.resolve(
            "don't stop the current work; just give me status",
            kind="control",
            reason="cancel",
        )

        self.assertEqual(disposition.route, IntentRoute.CONTINUE_CURRENT)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.PRESERVE)
        self.assertEqual(disposition.conflicting_work_ids, ())

    def test_project_mutation_queues_instead_of_replacing(self):
        disposition = self.resolve("Build the export screen too", kind="create_ticket")
        self.assertEqual(disposition.route, IntentRoute.QUEUE_PROJECT_WORK)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.PRESERVE)
        self.assertIn("repository", disposition.resource_claims)

    def test_direct_computer_action_stays_foreground_and_claims_the_desktop(self):
        disposition = self.resolve("open Chrome", kind="direct_action")

        self.assertEqual(disposition.route, IntentRoute.CONTINUE_CURRENT)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.PRESERVE)
        self.assertIn("desktop", disposition.resource_claims)

    def test_explicit_completed_redirect_is_the_only_default_preemption(self):
        disposition = self.resolve(
            "Actually instead, stop that and switch to the login bug",
            kind="create_ticket",
        )
        self.assertEqual(disposition.route, IntentRoute.REPLACE_CURRENT)
        self.assertEqual(
            disposition.authorization_effect,
            AuthorizationEffect.REVOKE_CONFLICTING,
        )

    def test_material_switch_ambiguity_asks_once(self):
        disposition = self.resolve("Should we switch to the release task?")
        self.assertEqual(disposition.route, IntentRoute.CLARIFY_PRIORITY)
        self.assertIn("queue", disposition.clarification_question.lower())

    def test_sidecar_requires_explicit_bounded_read_only_work(self):
        active = (ActiveWork("1:active"),)
        self.assertTrue(sidecar_eligible(
            source_text="In parallel, research and compare those two APIs",
            active_work=active,
        ))
        self.assertFalse(sidecar_eligible(
            source_text="In parallel, update the repository",
            active_work=active,
        ))
        self.assertFalse(sidecar_eligible(
            source_text="In parallel, inspect the browser",
            active_work=active,
            requested_resources=("desktop",),
        ))

    def test_sidecar_route_never_accepts_project_mutations(self):
        disposition = resolve_intent_disposition(
            intent_id="intent-2",
            action_kind="conversation",
            action_reason="",
            source_text="In parallel, research and compare the public docs",
            active_work=(ActiveWork("1:active"),),
        )
        self.assertEqual(disposition.route, IntentRoute.RUN_SIDECAR)

        mutation = self.resolve(
            "In parallel, research and update the implementation",
            kind="create_ticket",
        )
        self.assertEqual(mutation.route, IntentRoute.QUEUE_PROJECT_WORK)

    def test_sidecar_infers_exclusive_resources_and_queues_conflicts(self):
        for request, resource in (
            ("Meanwhile, inspect the repository", "repository"),
            ("In parallel, inspect the browser", "desktop"),
            ("In parallel, research the email channel", "external_side_effect"),
        ):
            disposition = self.resolve(request)
            self.assertEqual(disposition.route, IntentRoute.QUEUE_PROJECT_WORK)
            self.assertIn(resource, disposition.resource_claims)

    def test_session_controls_are_control_only(self):
        disposition = self.resolve("__PLAY__", kind="control", reason="play")
        self.assertEqual(disposition.route, IntentRoute.CONTROL_ONLY)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.NONE)

        speech_stop = self.resolve("Stop speaking", kind="control", reason="cancel")
        self.assertEqual(speech_stop.route, IntentRoute.CONTROL_ONLY)
        self.assertEqual(speech_stop.authorization_effect, AuthorizationEffect.PRESERVE)

    def test_real_same_turn_work_is_normalized_into_ordered_items_for_both_providers(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                items = normalize_voice_work_items(
                    "Fix login and add search",
                    relay_command_seq=7,
                    relay_command_id=f"{provider}-7",
                )

                self.assertEqual([item.source_text for item in items], ["Fix login", "add search"])
                self.assertEqual([item.within_turn_order for item in items], [1, 2])
                self.assertEqual(
                    [item.intent_id for item in items],
                    [f"{provider}-7:item:1", f"{provider}-7:item:2"],
                )

    def test_direct_action_after_project_work_is_a_separate_ordered_item(self):
        items = normalize_voice_work_items(
            "Fix login and open Chrome",
            relay_command_seq=8,
            relay_command_id="cmd-8",
        )

        self.assertEqual([item.source_text for item in items], ["Fix login", "open Chrome"])

    def test_go_ahead_and_work_phrase_stays_one_item(self):
        items = normalize_voice_work_items(
            "Go ahead and build the release",
            relay_command_seq=8,
            relay_command_id="cmd-8",
        )

        self.assertEqual([item.source_text for item in items], ["Go ahead and build the release"])

    def test_same_turn_abandonment_cancels_only_the_named_item(self):
        items = normalize_voice_work_items(
            "Dispatch RR-263 and add automatic compaction and fix export but never mind export",
            relay_command_seq=9,
            relay_command_id="cmd-9",
        )

        self.assertEqual(len(items), 4)
        self.assertEqual(items[0].lifecycle_state, "recognized")
        self.assertEqual(items[1].lifecycle_state, "recognized")
        self.assertEqual(items[2].lifecycle_state, "cancelled")
        self.assertEqual(items[3].cancellation_scope, CancellationScope.ITEM)
        self.assertEqual(items[3].target_intent_ids, (items[2].intent_id,))


if __name__ == "__main__":
    unittest.main()
