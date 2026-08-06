from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from command_actions import (  # noqa: E402
    CONTROL_COMMANDS,
    classify_command,
    create_ticket_for_command,
    format_command_for_agent,
    is_relay_runner_self_explanation,
    resolve_command_action,
)


class CommandActionsTests(unittest.TestCase):
    def test_internal_controls_are_no_ticket_actions(self):
        for command, reason in CONTROL_COMMANDS.items():
            with self.subTest(command=command):
                action = classify_command(command)

                self.assertEqual(action.kind, "control")
                self.assertFalse(action.requires_ticket)
                self.assertIsNone(action.ticket_id)
                self.assertEqual(action.reason, reason)
                self.assertEqual(format_command_for_agent(action), command)

    def test_trace_control_is_not_routed_as_ticket_work(self):
        action = classify_command('__TRACE__:{"kind":"ticket-created","ticket_id":"RR-9"}')

        self.assertEqual(action.kind, "control")
        self.assertFalse(action.requires_ticket)
        self.assertEqual(action.reason, "trace")

    def test_orchestrator_reply_control_is_not_routed_as_ticket_work(self):
        action = classify_command('__ORCHESTRATOR_REPLY__:{"text":"Done"}')

        self.assertEqual(action.kind, "control")
        self.assertFalse(action.requires_ticket)
        self.assertEqual(action.reason, "orchestrator_reply")

    def test_pending_work_instruction_is_not_routed_as_new_ticket(self):
        action = classify_command(
            "Once these tickets are done, review it, merge it, and rebuild and install the app."
        )

        self.assertEqual(action.kind, "control")
        self.assertFalse(action.requires_ticket)
        self.assertEqual(action.reason, "pending_work_instruction")

    def test_project_work_with_orchestrator_process_words_still_creates_ticket(self):
        action = classify_command(
            "Add radiuses to the notch edges. When I hover to expand to see what "
            "the traces are doing, add easing too. Those can be two separate "
            "tickets, and I am watching to see if the PM writes and dispatches "
            "the tickets or if the orchestrator does."
        )

        self.assertEqual(action.kind, "create_ticket")
        self.assertTrue(action.requires_ticket)

    def test_orchestrator_process_correction_is_not_routed_as_ticket_work(self):
        action = classify_command(
            "Why did you write the ticket? The entire point is so that you can "
            "dispatch my raw response straight to the orchestrator. So the "
            "orchestrator can write the ticket. Therefore, I can continue "
            "talking to you without interrupting the ticket writing process."
        )

        self.assertEqual(action.kind, "control")
        self.assertFalse(action.requires_ticket)
        self.assertEqual(action.reason, "orchestration_process_correction")

    def test_relay_runner_self_explanations_stay_in_fast_conversation(self):
        samples = [
            "What is Relay Runner?",
            "Could you explain what Relay Runner is and what it does?",
            "What is the core functionality of Relay Runner?",
            "Tell the audience about Relay Runner.",
            (
                "I'm demoing Relay Runner right now; please explain what it what "
                "it does to the audience."
            ),
            (
                "I might add this to the demo: when I present Relay Runner, "
                "briefly explain it to the audience."
            ),
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                action = classify_command(sample)

                self.assertTrue(is_relay_runner_self_explanation(sample))
                self.assertEqual(action.kind, "conversation")
                self.assertEqual(action.reason, "relay_runner_self_explanation")
                self.assertFalse(action.requires_ticket)

    def test_relay_runner_project_changes_do_not_use_self_explanation_shortcut(self):
        samples = [
            "Change what Relay Runner does when recording commands.",
            "Add a self-explanation shortcut to Relay Runner.",
            "Explain how to change Relay Runner's command routing.",
            "What is Relay Runner's command classification architecture?",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertFalse(is_relay_runner_self_explanation(sample))

        self.assertEqual(classify_command(samples[0]).kind, "create_ticket")
        self.assertEqual(classify_command(samples[1]).kind, "create_ticket")

    def test_negated_stop_status_request_is_not_a_cancel_control(self):
        action = resolve_command_action(
            "don't stop the current work; just give me status",
            relay_command={
                "relay_command_seq": 2,
                "relay_command_id": "cmd-2",
            },
        )

        self.assertEqual(action.kind, "conversation")
        self.assertEqual(action.reason, "")
        self.assertFalse(action.requires_ticket)

    def test_session_operations_stay_inline_instead_of_becoming_tickets(self):
        samples = [
            "commit everything to remote",
            "rebuild and install when everything is ready and commit to remote",
            "push main to origin",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                action = classify_command(sample)

                self.assertEqual(action.kind, "inline_work")
                self.assertFalse(action.requires_ticket)

    def test_direct_computer_requests_stay_with_the_foreground_pm(self):
        samples = [
            ("what's on my screen", "screen_observation"),
            ("open this folder in Finder", "desktop_control"),
            ("open Chrome", "desktop_control"),
            ("open Slack", "desktop_control"),
            ("click the Add project button", "desktop_control"),
        ]
        for sample, reason in samples:
            with self.subTest(sample=sample):
                action = classify_command(sample)

                self.assertEqual(action.kind, "direct_action")
                self.assertEqual(action.reason, reason)
                self.assertFalse(action.requires_ticket)

    def test_direct_computer_prompt_is_shell_first_and_keeps_messenger_tool_free(self):
        action = resolve_command_action(
            "open this folder in Finder",
            repo_path="/tmp/repo",
            relay_command={
                "relay_command_seq": 4,
                "relay_command_id": "cmd-4",
            },
        )

        prompt = format_command_for_agent(action)

        self.assertIn("action: direct_action", prompt)
        self.assertIn("Handle this directly in the foreground PM", prompt)
        self.assertIn("Do not create a ticket, dispatch a worker, or send this to the Relay daemon", prompt)
        self.assertIn("Prefer a deterministic shell or operating-system command", prompt)
        self.assertIn("Relay Vision", prompt)
        self.assertIn("Relay Actions", prompt)
        self.assertIn("The messenger remains tool-free", prompt)

    def test_project_work_with_open_word_still_requires_a_ticket(self):
        action = classify_command("fix the open source login retry bug")

        self.assertEqual(action.kind, "create_ticket")
        self.assertTrue(action.requires_ticket)

    def test_new_project_work_requires_refined_management_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            orch = repo / ".orchestrator"
            orch.mkdir()
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')

            action = resolve_command_action("fix the login retry bug", repo_path=repo)

            self.assertEqual(action.kind, "create_ticket")
            self.assertTrue(action.requires_ticket)
            self.assertIsNone(action.ticket_id)
            self.assertIsNone(action.ticket_path)
            self.assertFalse((orch / "RR-3.md").exists())
            self.assertEqual((orch / "config.toml").read_text(), 'prefix = "RR"\nnext_id = 3\n')

            prompt = format_command_for_agent(action)
            self.assertIn("action: create_ticket", prompt)
            self.assertIn("ticket_id: null", prompt)
            self.assertIn("Create or refine a visible ticket now", prompt)
            self.assertIn("You are the PM frontstage", prompt)
            self.assertIn("foreground orchestrator/PM owns command classification", prompt)
            self.assertNotIn("You are the foreground orchestrator", prompt)
            self.assertIn("Raw Relay command captures are private metadata", prompt)
            self.assertIn("Creating or editing visible `.orchestrator/` tickets is PM management work", prompt)
            self.assertIn("Do not implement the ticket yourself", prompt)

    def test_relay_command_metadata_is_preserved_without_visible_ticket(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            orch = repo / ".orchestrator"
            orch.mkdir()
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')
            relay_command = {
                "relay_command_seq": 7,
                "relay_command_id": "cmd-7",
            }

            action = resolve_command_action(
                "fix the login retry bug",
                repo_path=repo,
                relay_command=relay_command,
            )

            prompt = format_command_for_agent(action)
            self.assertFalse((orch / "RR-3.md").exists())
            self.assertEqual(action.relay_command_seq, 7)
            self.assertEqual(action.relay_command_id, "cmd-7")
            self.assertIn("relay_command_seq: 7", prompt)
            self.assertIn("relay_command_id: cmd-7", prompt)
            self.assertIn("pass relay_command_seq and relay_command_id", prompt)
            self.assertIn("foreground orchestrator/PM", prompt)

    def test_explicit_refined_ticket_creation_targets_resolved_child_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            parent_orch = workspace / ".orchestrator"
            parent_orch.mkdir()
            (parent_orch / "config.toml").write_text('prefix = "DE"\nnext_id = 12\n')

            child = workspace / "relay-runner"
            child_orch = child / ".orchestrator"
            child_orch.mkdir(parents=True)
            (child_orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')

            ticket_id, ticket_path = create_ticket_for_command(
                child,
                "Fix login retries after the foreground orchestrator resolved relay-runner.",
            )

            self.assertEqual(ticket_id, "RR-3")
            self.assertEqual(ticket_path, child_orch.resolve() / "RR-3.md")
            self.assertTrue(ticket_path.exists())
            self.assertNotIn(
                "Fix login retries after the foreground orchestrator resolved relay-runner.",
                ticket_path.read_text(),
            )
            self.assertFalse((parent_orch / "DE-12.md").exists())
            self.assertEqual((parent_orch / "config.toml").read_text(), 'prefix = "DE"\nnext_id = 12\n')

    def test_ticket_creation_applies_user_default_worker_sizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            orch = repo / ".orchestrator"
            orch.mkdir()
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')

            _, ticket_path = create_ticket_for_command(
                repo,
                "Fix the login retry bug.",
                general_config={
                    "subagent_sizing_policy": "user_default",
                    "provider": "codex",
                    "model": "sol",
                    "orchestrator_effort": "high",
                    "subagent_model": "strong",
                    "subagent_effort": "xhigh",
                },
            )

            raw = ticket_path.read_text()
            self.assertIn("worker_model: codex:sol", raw)
            self.assertIn("worker_effort: high", raw)
            self.assertIn("worker_sizing_rationale", raw)
            self.assertIn("Use my defaults preserves explicit stable provider selections", raw)

    def test_ticket_creation_omits_worker_sizing_when_orchestrator_decides(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            orch = repo / ".orchestrator"
            orch.mkdir()
            (orch / "config.toml").write_text('prefix = "RR"\nnext_id = 3\n')

            _, ticket_path = create_ticket_for_command(
                repo,
                "Fix the login retry bug.",
                general_config={"subagent_sizing_policy": "orchestrator_decides"},
            )

            self.assertNotIn("worker_model:", ticket_path.read_text())

    def test_existing_ticket_dispatch_attaches_to_ticket(self):
        action = classify_command("dispatch rr-7 to a worker")

        self.assertEqual(action.kind, "dispatch_ticket")
        self.assertTrue(action.requires_ticket)
        self.assertEqual(action.ticket_id, "RR-7")
        self.assertIn("action: dispatch_ticket", format_command_for_agent(action))

    def test_existing_ticket_update_attaches_to_ticket(self):
        action = classify_command("update RR-8 with the auth context")

        self.assertEqual(action.kind, "update_ticket")
        self.assertTrue(action.requires_ticket)
        self.assertEqual(action.ticket_id, "RR-8")

    def test_work_without_project_still_avoids_board_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            action = resolve_command_action("implement the sidebar", repo_path=tmp)

            self.assertEqual(action.kind, "create_ticket")
            self.assertTrue(action.requires_ticket)
            self.assertIsNone(action.ticket_id)
            self.assertFalse((Path(tmp) / ".orchestrator").exists())
            self.assertIn("Create or refine a visible ticket now", format_command_for_agent(action))


if __name__ == "__main__":
    unittest.main()
