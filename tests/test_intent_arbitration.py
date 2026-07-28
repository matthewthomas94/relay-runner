from __future__ import annotations

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(ROOT, "services"))

from intent_arbitration import (  # noqa: E402
    ActiveWork,
    AuthorizationEffect,
    IntentRoute,
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

    def test_project_mutation_queues_instead_of_replacing(self):
        disposition = self.resolve("Build the export screen too", kind="create_ticket")
        self.assertEqual(disposition.route, IntentRoute.QUEUE_PROJECT_WORK)
        self.assertEqual(disposition.authorization_effect, AuthorizationEffect.PRESERVE)
        self.assertIn("repository", disposition.resource_claims)

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


if __name__ == "__main__":
    unittest.main()
