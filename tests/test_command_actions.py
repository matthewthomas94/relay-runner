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

    def test_new_project_work_defers_visible_ticket_creation(self):
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
            self.assertIn("No visible ticket has been written yet", prompt)
            self.assertIn("Do not perform substantive source-code implementation directly", prompt)

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
                    "subagent_model": "strong",
                    "subagent_effort": "xhigh",
                },
            )

            raw = ticket_path.read_text()
            self.assertIn("worker_model: strong", raw)
            self.assertIn("worker_effort: xhigh", raw)
            self.assertIn("worker_sizing_rationale", raw)
            self.assertIn("Codex uses model_reasoning_effort and Claude uses --effort", raw)

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
            self.assertIn("No visible ticket has been written yet", format_command_for_agent(action))


if __name__ == "__main__":
    unittest.main()
