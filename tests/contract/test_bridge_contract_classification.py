"""Voice bridge contract: how a turn's wording is classified, as published in
the mailbox metadata and the acknowledgement (docs/specs/voice-bridge-contract.md,
"Commands, the inbox and the claim lifecycle")."""

from __future__ import annotations

import unittest

from bridge_contract_support import BridgeCase, wait_until


class ClassificationContract:
    def assertConversation(self, command: dict) -> None:
        self.assertEqual(command["action"], "conversation")
        self.assertIs(command["requires_ticket"], False)
        self.assertEqual(command["work_disposition"]["route"], "continue_current")
        self.assertEqual(command["work_disposition"]["authorization_effect"], "preserve")
        self.assertEqual(command["authorization_relationship"], "conversation")
        self.assertIs(command["preempt_provider"], False)

    def test_a_negated_stop_asking_for_status_preserves_the_current_work(self):
        """Classification: "don't stop the current work; just give me status"
        is a `conversation` that continues the current work: route
        `continue_current`, authorization `preserve`, no provider preemption."""
        self.assertConversation(self.claimed_turn("don't stop the current work; just give me status"))

    def test_a_demo_explanation_is_conversation(self):
        """Classification: asking the assistant to explain Relay Runner to an
        audience is a `conversation` with reason `relay_runner_self_explanation`."""
        command = self.claimed_turn("I'm demoing Relay Runner; please explain what it does to the audience.")
        self.assertConversation(command)
        self.assertEqual(command["reason"], "relay_runner_self_explanation")

    def test_a_question_followed_by_a_change_asks_one_clarification(self):
        """Classification: a status question followed by a change to the same
        ticket is one non-mutating `conversation` (reason
        `mixed_query_and_mutation_clarification`) whose prompt asks for one
        clarification. Nothing is authorized and nothing is posted to the
        daemon."""
        command = self.claimed_turn("What is the status of RR-325, then update RR-325.")
        self.assertConversation(command)
        self.assertEqual(command["reason"], "mixed_query_and_mutation_clarification")
        self.assertEqual(command["within_turn_order"], 1)
        self.assertIn("Ask one concise clarification", command["agent_prompt"])
        self.assertStays(lambda: not self.box.orchestrator.requests("/v1/orchestrator-session/command"))
        self.assertFalse([record for record in self.box.authorization_records()
                          if record.get("status") == "active"])

    def test_the_acknowledgement_never_repeats_a_secret(self):
        """Classification: the acknowledgement shown for a turn that mentions a
        password is generic; it repeats neither the secret nor the rest of the
        transcript."""
        command = self.turn("use password hunter2 for the deployment")
        acknowledgement = wait_until(
            lambda: [state for state in self.box.states("acknowledgement")
                     if state["status_event"]["command"]["relay_command_id"] == command["relay_command_id"]],
            message="the acknowledgement",
        )[0]
        self.assertTrue(acknowledgement["text"])
        self.assertNotIn("hunter2", acknowledgement["text"])
        self.assertNotIn("deployment", acknowledgement["text"])


class ClaudeClassification(ClassificationContract, BridgeCase):
    provider = "claude"


class CodexClassification(ClassificationContract, BridgeCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main()
